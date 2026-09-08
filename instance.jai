JRHI_Version :: struct {
    major: u32;
    minor: u32;
    patch: u32;
}

JRHI_Create_Descriptor :: struct {
    application_name:        string;
    application_version:     JRHI_Version;
    engine_name:             string;
    engine_version:          JRHI_Version;
    enable_validation_layer: bool;
}

JRHI_Context :: struct {
    allocator:    Allocator;
    instance:     VkInstance;
    physical_gpu: VkPhysicalDevice;
    virtual_gpu:  VkDevice;
    queue:        VkQueue;
    queue_family: u32;
}

#add_context jrhi: *JRHI_Context = null;

JRHI_VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation";

jrhi_to_vulkan_version :: (version: JRHI_Version) -> u32 {
    return VK_MAKE_API_VERSION(0, version.major, version.minor, version.patch);
}

jrhi_create :: (descriptor: JRHI_Create_Descriptor) -> bool {
    assert(!context.jrhi, "JRHI context already exists.");

    rhi := New(JRHI_Context);
    rhi.allocator = context.allocator;

    // Metadata shown by Vulkan tools and debuggers
    application_info: VkApplicationInfo;
    {
        using application_info;
        pApplicationName   = descriptor.application_name.data;
        applicationVersion = jrhi_to_vulkan_version(descriptor.application_version);
        pEngineName        = descriptor.engine_name.data;
        engineVersion      = jrhi_to_vulkan_version(descriptor.engine_version);
        apiVersion         = VK_API_VERSION_1_2;
    }

    // Vulkan validation layer
    layers: [1] *u8;
    layers[0] = JRHI_VALIDATION_LAYER_NAME.data;

    extensions: [1] *u8;

    // Settings for creating the Vulkan instance
    create_info: VkInstanceCreateInfo;
    {
        using create_info;
        pApplicationInfo = *application_info;

        if descriptor.enable_validation_layer {
            enabledLayerCount   = cast(u32) layers.count;
            ppEnabledLayerNames = layers.data;
        }

        #if OS == .MACOS {
            // MoltenVK needs this on macOS
            extensions[0] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME.data;

            flags                   = .ENUMERATE_PORTABILITY_BIT_KHR;
            enabledExtensionCount   = cast(u32) extensions.count;
            ppEnabledExtensionNames = extensions.data;
        }
    }

    // Create the Vulkan instance
    result := vkCreateInstance(*create_info, null, *rhi.instance);
    if result != .SUCCESS {
        free(rhi,, rhi.allocator);
        return false;
    }

    context.jrhi = rhi;
    return true;
}

jrhi_destroy :: () {
    assert(xx context.jrhi, "JRHI context does not exist.");

    rhi := context.jrhi;
    vkDestroyInstance(rhi.instance, null);
    context.jrhi = null;
    free(rhi,, rhi.allocator);
}
