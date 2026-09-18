#import "Basic";

Vulkan :: #import,file "../modules/Vulkan/module.jai";

#scope_export

// The result of an operation that can fail because of the system or GPU.
Result :: enum {
    SUCCESS;
    UNSUPPORTED;
    FAILED;
}

// Controls how JRHI uses the Khronos validation layer.
Validation :: enum {
    DISABLED;
    OPTIONAL;
    REQUIRED;
}

// Creates the active JRHI context.
//
// JRHI currently chooses a graphics-capable GPU automatically and creates one graphics queue.
// GPU selection and dedicated queues are not exposed yet.
create :: (
    application_name: string,
    validation:       Validation = .DISABLED,
) -> Result {
    assert(context.jrhi == null, "A JRHI context already exists.");

    rhi          := New(JRHI_Context);
    rhi.allocator = context.allocator;

    created := false;
    defer if !created then destroy_context(rhi);

    result := create_instance(rhi, application_name, validation);
    if result != .SUCCESS then return result;

    if rhi.validation_enabled {
        result = create_debug_messenger(rhi);
        if result != .SUCCESS then return result;
    }

    result = choose_graphics_gpu(rhi);
    if result != .SUCCESS then return result;

    result = create_device(rhi);
    if result != .SUCCESS then return result;

    context.jrhi = rhi;
    created      = true;

    return .SUCCESS;
}

// Waits for JRHI work to finish, then destroys the active JRHI context.
destroy :: () {
    rhi := current();

    assert(
        Vulkan.vkDeviceWaitIdle(rhi.device) == .SUCCESS,
        "Could not wait for the JRHI device to become idle."
    );

    destroy_context(rhi);
    context.jrhi = null;
}

#scope_file

JRHI_Owned_Resources :: enum_flags u8 {
    NONE;
    INSTANCE;
    DEBUG_MESSENGER;
    DEVICE;
}

JRHI_Context :: struct {
    allocator:               Allocator;
    owned_resources:         JRHI_Owned_Resources;
    instance:                Vulkan.VkInstance;
    debug_messenger:         Vulkan.VkDebugUtilsMessengerEXT;
    validation_enabled:   bool;
    physical_gpu:         Vulkan.VkPhysicalDevice;
    device:               Vulkan.VkDevice;
    graphics_queue:       Vulkan.VkQueue;
    graphics_queue_index: u32;
}

// This is the one JRHI context attached to Jai's implicit context.
#add_context jrhi: *JRHI_Context;

current :: () -> *JRHI_Context {
    assert(
        context.jrhi != null,
        "No current JRHI context. Did you call JRHI.create()?"
    );
    return context.jrhi;
}

create_instance :: (
    rhi: *JRHI_Context,
    application_name: string,
    validation: Validation,
) -> Result {
    app_info: Vulkan.VkApplicationInfo;
    {
        using app_info;
        pApplicationName   = temp_c_string(application_name);
        applicationVersion = Vulkan.VK_MAKE_API_VERSION(0, 0, 1, 0);
        pEngineName        = temp_c_string("JRHI");
        engineVersion      = Vulkan.VK_MAKE_API_VERSION(0, 0, 1, 0);
        apiVersion         = Vulkan.VK_API_VERSION_1_3;
    }

    create_info: Vulkan.VkInstanceCreateInfo;
    create_info.pApplicationInfo = *app_info;

    extensions: [2] *u8;
    extension_count: u32;

    #if OS == .MACOS {
        extensions[extension_count] = Vulkan.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME.data;
        extension_count += 1;

        create_info.flags = .ENUMERATE_PORTABILITY_BIT_KHR;
    }

    if validation != .DISABLED {
        VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation";
        layers: [1] *u8;
        layers[0] = VALIDATION_LAYER_NAME.data;

        create_info.enabledLayerCount   = layers.count;
        create_info.ppEnabledLayerNames = layers.data;

        // The debug messenger reports validation messages through Jai's logger.
        extensions[extension_count] = Vulkan.VK_EXT_DEBUG_UTILS_EXTENSION_NAME.data;
        extension_count += 1;
        rhi.validation_enabled = true;
    }

    if extension_count > 0 {
        create_info.enabledExtensionCount   = extension_count;
        create_info.ppEnabledExtensionNames = extensions.data;
    }

    result := Vulkan.vkCreateInstance(*create_info, null, *rhi.instance);
    if result == .ERROR_LAYER_NOT_PRESENT && validation == .OPTIONAL {
        log("Khronos validation layer is unavailable. Continuing without validation.");

        create_info.enabledLayerCount   = 0;
        create_info.ppEnabledLayerNames = null;
        rhi.validation_enabled          = false;
        result                          = Vulkan.vkCreateInstance(*create_info, null, *rhi.instance);
    }

    if result != .SUCCESS {
        if result == .ERROR_INCOMPATIBLE_DRIVER || result == .ERROR_LAYER_NOT_PRESENT {
            return .UNSUPPORTED;
        }
        return .FAILED;
    }

    rhi.owned_resources |= .INSTANCE;
    return .SUCCESS;
}

CREATE_DEBUG_MESSENGER_PROC  :: "vkCreateDebugUtilsMessengerEXT";
DESTROY_DEBUG_MESSENGER_PROC :: "vkDestroyDebugUtilsMessengerEXT";

debug_callback :: (
    message_severity: Vulkan.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_types:    Vulkan.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data:    *Vulkan.VkDebugUtilsMessengerCallbackDataEXT,
    user_data:        *void,
) -> Vulkan.VkBool32 #c_call {
    push_context {
        if message_severity & .ERROR_BIT_EXT {
            log("Vulkan validation error: %", callback_data.pMessage);
        } else {
            log("Vulkan validation warning: %", callback_data.pMessage);
        }
    }

    return Vulkan.VK_FALSE;
}

create_debug_messenger :: (rhi: *JRHI_Context) -> Result {
    create_debug_messenger: Vulkan.PFN_vkCreateDebugUtilsMessengerEXT =
        xx Vulkan.vkGetInstanceProcAddr(rhi.instance, CREATE_DEBUG_MESSENGER_PROC);

    create_info: Vulkan.VkDebugUtilsMessengerCreateInfoEXT;
    {
        using create_info;
        messageSeverity = .WARNING_BIT_EXT | .ERROR_BIT_EXT;
        messageType     = .GENERAL_BIT_EXT | .VALIDATION_BIT_EXT | .PERFORMANCE_BIT_EXT;
        pfnUserCallback = debug_callback;
    }

    result := create_debug_messenger(rhi.instance, *create_info, null, *rhi.debug_messenger);
    if result != .SUCCESS then return .FAILED;

    rhi.owned_resources |= .DEBUG_MESSENGER;
    return .SUCCESS;
}

choose_graphics_gpu :: (rhi: *JRHI_Context) -> Result {
    physical_gpus, result := Vulkan.vkEnumeratePhysicalDevices(rhi.instance);
    defer free(physical_gpus.data);

    if result != .SUCCESS then return .FAILED;

    found_gpu := false;

    for physical_gpus {
        physical_gpu := it;

        properties: Vulkan.VkPhysicalDeviceProperties;
        Vulkan.vkGetPhysicalDeviceProperties(physical_gpu, *properties);

        // JRHI requires Vulkan 1.3.
        if properties.apiVersion < Vulkan.VK_API_VERSION_1_3 then continue;

        // A discrete GPU wins over an earlier integrated GPU.
        if found_gpu && properties.deviceType != .DISCRETE_GPU then continue;

        queue_families := Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical_gpu);
        defer free(queue_families.data);

        for queue_families {
            if !(it.queueFlags & .GRAPHICS_BIT) then continue;

            rhi.physical_gpu         = physical_gpu;
            rhi.graphics_queue_index = cast(u32) it_index;
            found_gpu                = true;
            break;
        }

        if found_gpu && properties.deviceType == .DISCRETE_GPU then break;
    }

    if !found_gpu then return .UNSUPPORTED;
    return .SUCCESS;
}

create_device :: (rhi: *JRHI_Context) -> Result {
    priority: float = 1;

    queue_create_info: Vulkan.VkDeviceQueueCreateInfo;
    {
        using queue_create_info;
        queueFamilyIndex = rhi.graphics_queue_index;
        queueCount       = 1;
        pQueuePriorities = *priority;
    }

    create_info: Vulkan.VkDeviceCreateInfo;
    {
        using create_info;
        queueCreateInfoCount = 1;
        pQueueCreateInfos    = *queue_create_info;

        #if OS == .MACOS {
            extensions: [1] *u8;
            extensions[0] = Vulkan.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME.data;

            enabledExtensionCount   = extensions.count;
            ppEnabledExtensionNames = extensions.data;
        }
    }

    result := Vulkan.vkCreateDevice(rhi.physical_gpu, *create_info, null, *rhi.device);
    if result != .SUCCESS then return .FAILED;

    Vulkan.vkGetDeviceQueue(rhi.device, rhi.graphics_queue_index, 0, *rhi.graphics_queue);
    rhi.owned_resources |= .DEVICE;
    return .SUCCESS;
}

destroy_context :: (rhi: *JRHI_Context) {
    if rhi.owned_resources & .DEBUG_MESSENGER {
        destroy_debug_messenger: Vulkan.PFN_vkDestroyDebugUtilsMessengerEXT =
            xx Vulkan.vkGetInstanceProcAddr(rhi.instance, DESTROY_DEBUG_MESSENGER_PROC);

        destroy_debug_messenger(rhi.instance, rhi.debug_messenger, null);
    }

    if rhi.owned_resources & .DEVICE {
        Vulkan.vkDestroyDevice(rhi.device, null);
    }

    if rhi.owned_resources & .INSTANCE {
        Vulkan.vkDestroyInstance(rhi.instance, null);
    }

    free(rhi,, rhi.allocator);
}
