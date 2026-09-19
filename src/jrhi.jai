#import "Basic";
#import "Hash_Table";

Vulkan :: #import,file "../modules/Vulkan/module.jai";

#scope_export

// The result of an operation that can fail because of the system or GPU.
Result :: enum {
    SUCCESS;       // The operation completed.
    UNSUPPORTED;   // The machine cannot provide a required JRHI feature.
    OUT_OF_MEMORY; // The CPU or GPU ran out of memory.
    FAILED;        // An unexpected Vulkan or system error occurred.
}

// Controls how JRHI uses the Khronos validation layer.
Validation :: enum {
    DISABLED; // Do not use the validation layer.
    OPTIONAL; // Use the layer when installed, otherwise continue without it.
    REQUIRED; // Fail creation when the layer is not installed.
}

// A 64-bit address that can be used by GPU shaders.
GPU_Pointer :: #type,distinct u64;

// One CPU-writable GPU memory allocation.
Memory :: struct {
    cpu:  *void;        // A persistent CPU mapping of this allocation.
    gpu:  GPU_Pointer;  // The start of this allocation in GPU virtual memory.
    size: s64;          // The requested allocation size in bytes.
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

    rhi                         := New(JRHI_Context);
    rhi.allocator                = context.allocator;
    rhi.memory_records.allocator = rhi.allocator;

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

// Allocates CPU-writable, GPU-addressable memory.
// The returned Memory must not be copied and must later be passed to free.
alloc :: (allocation_size: s64) -> Memory, Result {
    assert(allocation_size > 0, "JRHI allocation size must be greater than zero.");

    rhi := current();

    record: Memory_Record;
    completed := false;
    defer if !completed then destroy_memory_record(rhi, *record);

    buffer_info: Vulkan.VkBufferCreateInfo;
    {
        using buffer_info;
        size        = cast(u64) allocation_size;
        // The allocation can receive uploads, be copied from, and be read by shaders.
        usage       = .TRANSFER_SRC_BIT | .TRANSFER_DST_BIT |
                      .STORAGE_BUFFER_BIT | .SHADER_DEVICE_ADDRESS_BIT;
        sharingMode = .EXCLUSIVE;
    }

    vulkan_result := Vulkan.vkCreateBuffer(rhi.device, *buffer_info, null, *record.buffer);
    if vulkan_result != .SUCCESS then return .{}, result_from_vulkan(vulkan_result);
    record.owned_resources |= .BUFFER;

    // Vulkan tells us which memory types and alignment this buffer accepts.
    memory_requirements: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetBufferMemoryRequirements(rhi.device, record.buffer, *memory_requirements);

    found_memory_type, memory_type_index, host_is_coherent :=
        choose_cpu_write_memory_type(rhi, memory_requirements.memoryTypeBits);
    if !found_memory_type then return .{}, .UNSUPPORTED;

    // This flag allows Vulkan to expose a 64-bit GPU address for the memory.
    address_flags: Vulkan.VkMemoryAllocateFlagsInfo;
    address_flags.flags = .DEVICE_ADDRESS_BIT;

    allocate_info: Vulkan.VkMemoryAllocateInfo;
    {
        using allocate_info;
        pNext            = *address_flags;
        allocationSize   = memory_requirements.size;
        memoryTypeIndex  = memory_type_index;
    }

    vulkan_result = Vulkan.vkAllocateMemory(rhi.device, *allocate_info, null, *record.device_memory);
    if vulkan_result != .SUCCESS then return .{}, result_from_vulkan(vulkan_result);
    record.owned_resources |= .DEVICE_MEMORY;

    vulkan_result = Vulkan.vkBindBufferMemory(rhi.device, record.buffer, record.device_memory, 0);
    if vulkan_result != .SUCCESS then return .{}, result_from_vulkan(vulkan_result);

    // Keep the allocation mapped so memory.cpu is always ready for CPU writes.
    mapped_memory: *void;
    vulkan_result = Vulkan.vkMapMemory(
        rhi.device,
        record.device_memory,
        0,
        Vulkan.VK_WHOLE_SIZE,
        0,
        *mapped_memory,
    );
    if vulkan_result != .SUCCESS then return .{}, result_from_vulkan(vulkan_result);
    record.owned_resources |= .MAPPED;

    // Ask Vulkan for the buffer's GPU virtual address.
    address_info: Vulkan.VkBufferDeviceAddressInfo;
    address_info.buffer = record.buffer;
    record.gpu          = cast(GPU_Pointer) Vulkan.vkGetBufferDeviceAddress(
        rhi.device,
        *address_info
    );
    if cast(u64) record.gpu == 0 then return .{}, .FAILED;

    record.size             = allocation_size;
    record.host_is_coherent = host_is_coherent;
    table_add(*rhi.memory_records, record.gpu, record);

    completed = true;
    return .{mapped_memory, record.gpu, allocation_size}, .SUCCESS;
}

// Frees memory and resets the caller's Memory value to zero.
free :: (memory: *Memory) {
    assert(memory != null, "JRHI memory does not exist.");

    rhi           := current();
    found, record := table_remove(*rhi.memory_records, memory.gpu);

    assert(found, "JRHI memory is not allocated or was already freed.");

    destroy_memory_record(rhi, *record);
    memory.* = .{};
}

gpu_offset :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    assert(offset >= 0, "JRHI GPU offset must not be negative.");

    address := cast(u64) pointer;
    result  := address + cast(u64) offset;

    assert(result >= address, "JRHI GPU pointer overflowed.");
    return cast(GPU_Pointer) result;
}

operator + :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    return gpu_offset(pointer, offset);
}

operator - :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    assert(offset >= 0, "JRHI GPU offset must not be negative.");

    address         := cast(u64) pointer;
    offset_unsigned := cast(u64) offset;

    assert(offset_unsigned <= address, "JRHI GPU pointer underflowed.");
    return cast(GPU_Pointer) (address - offset_unsigned);
}

// Returns a GPU pointer to a byte range inside memory.
gpu_at :: (memory: *Memory, offset: s64, size: s64) -> GPU_Pointer {
    // Unlike raw pointer arithmetic, this helper checks that the whole range is owned.
    assert(memory != null,               "JRHI memory does not exist.");
    assert(offset >= 0,                  "JRHI GPU offset must not be negative.");
    assert(size >= 0,                    "JRHI GPU range size must not be negative.");
    assert(offset <= memory.size,        "JRHI GPU offset is outside its memory allocation.");
    assert(size <= memory.size - offset, "JRHI GPU range is outside its memory allocation.");

    return gpu_offset(memory.gpu, offset);
}

#scope_file

// These flags describe which Vulkan objects must be destroyed during cleanup.
JRHI_Owned_Resources :: enum_flags u8 {
    NONE;             // No Vulkan object has been created.
    INSTANCE;         // instance must be destroyed.
    DEBUG_MESSENGER;  // debug_messenger must be destroyed before instance.
    DEVICE;           // device and every live Memory allocation must be destroyed.
}

Memory_Owned_Resources :: enum_flags u8 {
    NONE;          // No Vulkan object has been created.
    BUFFER;        // buffer must be destroyed.
    DEVICE_MEMORY; // device_memory must be freed.
    MAPPED;        // device_memory must be unmapped before it is freed.
}

JRHI_Context :: struct {
    allocator:            Allocator;                         // Allocator for JRHI's private state.
    owned_resources:      JRHI_Owned_Resources;              // Vulkan objects created so far.
    memory_records:       Table(GPU_Pointer, Memory_Record); // Live allocations, keyed by GPU address.
    instance:             Vulkan.VkInstance;                 // Connection to the Vulkan implementation.
    debug_messenger:      Vulkan.VkDebugUtilsMessengerEXT;   // Validation message callback, when enabled.
    validation_enabled:   bool;                              // Whether the validation layer was created.
    physical_gpu:         Vulkan.VkPhysicalDevice;           // GPU selected for this context.
    device:               Vulkan.VkDevice;                   // Logical device used to allocate and submit work.
    graphics_queue:       Vulkan.VkQueue;                    // The one graphics queue currently exposed.
    graphics_queue_index: u32;                               // Family index of graphics_queue.
}

Memory_Record :: struct {
    gpu:              GPU_Pointer;            // Key used to find this record during free.
    buffer:           Vulkan.VkBuffer;        // Buffer that gives the allocation its GPU address.
    device_memory:    Vulkan.VkDeviceMemory;  // Vulkan memory bound to buffer.
    size:             s64;                    // Requested byte count, not Vulkan's aligned allocation size.
    host_is_coherent: bool;                   // False means future submission must flush CPU writes.
    owned_resources:  Memory_Owned_Resources; // Handles that need cleanup after partial creation.

    // @Priority:
    // Replace individual Vulkan allocations with heap suballocation.
    // Defer frees until GPU submissions using this memory complete.
    // Flush non-coherent CPU-write memory before GPU submission.
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

result_from_vulkan :: (result: Vulkan.VkResult) -> Result {
    if result == .ERROR_OUT_OF_HOST_MEMORY || result == .ERROR_OUT_OF_DEVICE_MEMORY {
        return .OUT_OF_MEMORY;
    }

    return .FAILED;
}

choose_cpu_write_memory_type :: (
    rhi: *JRHI_Context,
    memory_type_bits: u32,
) -> bool, u32, bool {
    // Read the memory heaps and memory types exposed by the chosen GPU.
    memory_properties: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(rhi.physical_gpu, *memory_properties);

    best_score: s32 = -1;
    best_index: u32;
    best_is_coherent := false;

    // A host-visible type is required. Prefer coherent memory, then local memory.
    for memory_type, index: memory_properties.memoryTypes {
        if index >= memory_properties.memoryTypeCount then break;

        memory_type_bit: u32 = cast(u32) 1 << cast(u32) index;
        if !(memory_type_bits & memory_type_bit)            then continue;
        if !(memory_type.propertyFlags & .HOST_VISIBLE_BIT) then continue;

        score: s32;
        if memory_type.propertyFlags & .HOST_COHERENT_BIT then score += 2;
        if memory_type.propertyFlags & .DEVICE_LOCAL_BIT  then score += 1;

        if score > best_score {
            best_score       = score;
            best_index       = cast(u32) index;
            best_is_coherent = (memory_type.propertyFlags & .HOST_COHERENT_BIT) != 0;
        }
    }

    return best_score >= 0, best_index, best_is_coherent;
}

destroy_memory_record :: (rhi: *JRHI_Context, record: *Memory_Record) {
    if record.owned_resources & .MAPPED {
        Vulkan.vkUnmapMemory(rhi.device, record.device_memory);
    }

    if record.owned_resources & .DEVICE_MEMORY {
        Vulkan.vkFreeMemory(rhi.device, record.device_memory, null);
    }

    if record.owned_resources & .BUFFER {
        Vulkan.vkDestroyBuffer(rhi.device, record.buffer, null);
    }
}

destroy_live_memory_records :: (rhi: *JRHI_Context) {
    // destroy is a safety net for leaks; normal code should call JRHI.free itself.
    for record: rhi.memory_records {
        log("JRHI destroyed a live memory allocation of % bytes.", record.size);
        destroy_memory_record(rhi, *record);
    }

    deinit(*rhi.memory_records);
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

        // Query support for the GPU-pointer feature before selecting this GPU.
        device_address_features: Vulkan.VkPhysicalDeviceBufferDeviceAddressFeatures;
        features: Vulkan.VkPhysicalDeviceFeatures2;
        features.pNext = *device_address_features;
        Vulkan.vkGetPhysicalDeviceFeatures2(physical_gpu, *features);

        // JRHI requires 64-bit GPU pointers.
        if device_address_features.bufferDeviceAddress != Vulkan.VK_TRUE then continue;

        // A discrete GPU wins over an earlier integrated GPU.
        if found_gpu && properties.deviceType != .DISCRETE_GPU then continue;

        // This first version uses one queue that can execute graphics commands.
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
    // Vulkan uses this priority if several queues compete for GPU time.
    priority: float = 1;

    // Enable the feature required by JRHI.GPU_Pointer.
    device_address_features: Vulkan.VkPhysicalDeviceBufferDeviceAddressFeatures;
    device_address_features.bufferDeviceAddress = Vulkan.VK_TRUE;

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
        pNext                = *device_address_features;

        #if OS == .MACOS {
            // MoltenVK requires this extension when creating a logical device.
            extensions: [1] *u8;
            extensions[0] = Vulkan.VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME.data;

            enabledExtensionCount   = extensions.count;
            ppEnabledExtensionNames = extensions.data;
        }
    }

    result := Vulkan.vkCreateDevice(rhi.physical_gpu, *create_info, null, *rhi.device);
    if result == .ERROR_FEATURE_NOT_PRESENT then return .UNSUPPORTED;
    if result != .SUCCESS                   then return .FAILED;

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
        // Free leaked Memory values while the device still owns their Vulkan handles.
        Vulkan.vkDeviceWaitIdle(rhi.device);
        destroy_live_memory_records(rhi);
        Vulkan.vkDestroyDevice(rhi.device, null);
    }

    if rhi.owned_resources & .INSTANCE {
        Vulkan.vkDestroyInstance(rhi.instance, null);
    }

    // Return the private context through the allocator that created it.
    free(rhi,, rhi.allocator);
}
