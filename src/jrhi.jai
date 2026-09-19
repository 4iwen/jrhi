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

// Controls which processor can access an allocation through its CPU mapping.
Memory_Access :: enum {
    GPU_ONLY;  // GPU reads and writes; Memory.cpu is null.
    CPU_WRITE; // CPU writes and GPU reads.
    CPU_READ;  // GPU writes and CPU reads after JRHI.read.
}

// A list of GPU commands.
// A command list is consumed and reset to zero by submit.
Command_List :: #type,distinct u64;

// One GPU-addressable memory allocation.
Memory :: struct {
    cpu:  *void;        // Persistent CPU mapping, or null for GPU_ONLY memory.
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
    assert(context.jrhi == null, "A JRHI context already exists. Call JRHI.destroy before creating another context.");

    rhi                         := New(JRHI_Context);
    rhi.allocator                = context.allocator;
    rhi.memory_records.allocator = rhi.allocator;
    rhi.deferred_memory.allocator = rhi.allocator;

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

    result = create_command_list_storage(rhi);
    if result != .SUCCESS then return result;

    context.jrhi = rhi;
    rhi.usable   = true;
    created      = true;

    return .SUCCESS;
}

// Waits for JRHI work to finish, then destroys the active JRHI context.
destroy :: () {
    rhi := current();
    destroy_context(rhi);
    context.jrhi = null;
}

// Allocates GPU-addressable memory with the requested CPU access.
// The returned Memory must not be copied and must later be passed to free or defer_free.
alloc :: (allocation_size: s64, access: Memory_Access) -> Memory, Result {
    assert(allocation_size > 0, "JRHI allocation size must be greater than zero. Pass the number of bytes you need.");

    rhi := usable_context();

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
        choose_memory_type(rhi, memory_requirements.memoryTypeBits, access);
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

    mapped_memory: *void;
    if access != .GPU_ONLY {
        // Keep CPU-visible allocations mapped for their entire lifetime.
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
    }

    // Ask Vulkan for the buffer's GPU virtual address.
    address_info: Vulkan.VkBufferDeviceAddressInfo;
    address_info.buffer = record.buffer;
    record.gpu          = cast(GPU_Pointer) Vulkan.vkGetBufferDeviceAddress(
        rhi.device,
        *address_info
    );
    if cast(u64) record.gpu == 0 then return .{}, .FAILED;

    record.size             = allocation_size;
    record.access           = access;
    record.host_is_coherent = host_is_coherent;
    table_add(*rhi.memory_records, record.gpu, record);

    completed = true;
    return .{mapped_memory, record.gpu, allocation_size}, .SUCCESS;
}

// Makes GPU writes visible through memory.cpu.
read :: (memory: *Memory) -> Result {
    assert(memory != null, "JRHI memory does not exist. Pass a valid Memory pointer to JRHI.read.");
    return read(memory, offset = 0, size = memory.size);
}

// Makes one GPU-written byte range visible through memory.cpu.
read :: (memory: *Memory, offset: s64, size: s64) -> Result {
    rhi := usable_context();
    assert(memory != null,               "JRHI memory does not exist. Pass a valid Memory pointer to JRHI.read.");
    assert(offset >= 0,                  "JRHI read offset must not be negative. Use a byte offset of zero or greater.");
    assert(size > 0,                     "JRHI read size must be greater than zero. Pass the number of bytes to read.");
    assert(offset <= memory.size,        "JRHI read offset is outside its memory allocation. Use an offset within memory.");
    assert(size <= memory.size - offset, "JRHI read range is outside its memory allocation. Reduce size or choose a valid offset.");

    record := memory_record(rhi, memory);
    assert(
        record.access == .CPU_READ,
        "JRHI.read requires memory allocated with access = .CPU_READ. Allocate a CPU_READ memory value for GPU-to-CPU data."
    );
    assert(
        record.recording_command_list == 0,
        "JRHI.read cannot run while a command list uses this memory. Call JRHI.submit(*command_list) before reading it."
    );

    if record.host_is_coherent then return .SUCCESS;

    range: Vulkan.VkMappedMemoryRange;
    range.memory = record.device_memory;
    range.offset = aligned_memory_offset(rhi, offset);
    range.size   = Vulkan.VK_WHOLE_SIZE;

    vulkan_result := Vulkan.vkInvalidateMappedMemoryRanges(rhi.device, 1, *range);
    return result_from_vulkan(vulkan_result);
}

// Frees memory and resets the caller's Memory value to zero.
free :: (memory: *Memory) {
    assert(memory != null, "JRHI memory does not exist. Pass a valid Memory pointer to JRHI.free.");

    rhi    := usable_context();
    record := memory_record(rhi, memory);
    assert(
        record.recording_command_list == 0,
        "JRHI memory is used by a command list and cannot be freed yet. Use JRHI.defer_free(*command_list, *memory), then call JRHI.submit(*command_list)."
    );

    found, removed_record := table_remove(*rhi.memory_records, memory.gpu);
    assert(found, "JRHI memory is not allocated or was already freed. Allocate memory with JRHI.alloc before freeing it.");

    destroy_memory_record(rhi, *removed_record);
    memory.* = .{};
}

// Frees memory after command_list has finished executing.
// memory becomes invalid immediately and cannot be used by later commands.
defer_free :: (command_list: *Command_List, memory: *Memory) {
    rhi := usable_context();
    assert_command_list(rhi, command_list);
    assert(memory != null, "JRHI memory does not exist. Pass a valid Memory pointer to JRHI.defer_free.");

    found, record := table_remove(*rhi.memory_records, memory.gpu);
    assert(found, "JRHI memory is not allocated or was already freed. Allocate memory with JRHI.alloc before deferring its free.");

    array_add(*rhi.deferred_memory, record);
    memory.* = .{};
}

// Starts recording the command list.
begin_command_list :: () -> Command_List, Result {
    rhi := usable_context();
    assert(rhi.active_command_list == 0, "A JRHI command list is already recording. Call JRHI.submit(*command_list) before starting another list.");

    begin_info: Vulkan.VkCommandBufferBeginInfo;
    begin_info.flags = .ONE_TIME_SUBMIT_BIT;

    vulkan_result := Vulkan.vkBeginCommandBuffer(rhi.command_buffer, *begin_info);
    if vulkan_result != .SUCCESS then return 0, result_from_vulkan(vulkan_result);

    rhi.next_command_list += 1;
    assert(rhi.next_command_list != 0, "JRHI command list identifiers are exhausted. Destroy and recreate the JRHI context.");
    rhi.active_command_list = rhi.next_command_list;

    return cast(Command_List) rhi.active_command_list, .SUCCESS;
}

// Fills the whole allocation with one repeated 32-bit value.
fill :: (command_list: *Command_List, memory: *Memory, value: u32) {
    fill(command_list, memory, offset = 0, size = memory.size, value = value);
}

// Fills one byte range with one repeated 32-bit value.
// offset and size must be multiples of four because Vulkan fills u32 values.
fill :: (
    command_list: *Command_List,
    memory:       *Memory,
    offset:       s64,
    size:         s64,
    value:        u32,
) {
    rhi := usable_context();
    assert_command_list(rhi, command_list);
    assert(memory != null,               "JRHI fill memory does not exist. Pass a valid Memory pointer.");
    assert(offset >= 0,                  "JRHI fill offset must not be negative. Use a byte offset of zero or greater.");
    assert(size > 0,                     "JRHI fill size must be greater than zero. Pass the number of bytes to fill.");
    assert(offset <= memory.size,        "JRHI fill offset is outside its memory allocation. Use an offset within memory.");
    assert(size <= memory.size - offset, "JRHI fill range is outside its memory allocation. Reduce size or choose a valid offset.");
    assert(offset % 4 == 0,              "JRHI fill offset must be a multiple of four bytes. Vulkan fill writes repeated u32 values.");
    assert(size % 4 == 0,                "JRHI fill size must be a multiple of four bytes. Vulkan fill writes repeated u32 values.");

    record := memory_record(rhi, memory);
    assert(
        record.access != .CPU_WRITE,
        "JRHI.fill cannot write CPU_WRITE memory. Use access = .GPU_ONLY or .CPU_READ for GPU-written data."
    );
    mark_memory_used(rhi, record);
    Vulkan.vkCmdFillBuffer(
        rhi.command_buffer,
        record.buffer,
        cast(Vulkan.VkDeviceSize) offset,
        cast(Vulkan.VkDeviceSize) size,
        value,
    );

    if record.access == .CPU_READ then make_gpu_writes_visible_to_cpu(rhi);
}

// Copies one byte range between two allocations.
copy :: (
    command_list:      *Command_List,
    destination:       *Memory,
    destination_offset: s64,
    source:            *Memory,
    source_offset:     s64,
    size:              s64,
) {
    rhi := usable_context();
    assert_command_list(rhi, command_list);
    assert(destination != null,                           "JRHI copy destination does not exist. Pass a valid destination Memory pointer.");
    assert(source != null,                                "JRHI copy source does not exist. Pass a valid source Memory pointer.");
    assert(destination_offset >= 0,                       "JRHI copy destination offset must not be negative. Use a byte offset of zero or greater.");
    assert(source_offset >= 0,                            "JRHI copy source offset must not be negative. Use a byte offset of zero or greater.");
    assert(size > 0,                                      "JRHI copy size must be greater than zero. Pass the number of bytes to copy.");
    assert(destination_offset <= destination.size,        "JRHI copy destination offset is outside its memory allocation. Use an offset within destination.");
    assert(size <= destination.size - destination_offset, "JRHI copy destination range is outside its memory allocation. Reduce size or choose a valid destination offset.");
    assert(source_offset <= source.size,                  "JRHI copy source offset is outside its memory allocation. Use an offset within source.");
    assert(size <= source.size - source_offset,           "JRHI copy source range is outside its memory allocation. Reduce size or choose a valid source offset.");

    destination_record := memory_record(rhi, destination);
    source_record      := memory_record(rhi, source);
    assert(
        source_record.access != .CPU_READ,
        "JRHI.copy cannot read CPU_READ memory on the GPU. Use access = .GPU_ONLY or .CPU_WRITE for the source."
    );
    assert(
        destination_record.access != .CPU_WRITE,
        "JRHI.copy cannot write CPU_WRITE memory on the GPU. Use access = .GPU_ONLY or .CPU_READ for the destination."
    );
    assert(
        destination_record != source_record ||
        destination_offset + size <= source_offset ||
        source_offset + size <= destination_offset,
        "JRHI copy source and destination ranges overlap. Use separate ranges or copy through another allocation."
    );

    mark_memory_used(rhi, destination_record);
    mark_memory_used(rhi, source_record);

    region: Vulkan.VkBufferCopy;
    region.srcOffset = cast(Vulkan.VkDeviceSize) source_offset;
    region.dstOffset = cast(Vulkan.VkDeviceSize) destination_offset;
    region.size      = cast(Vulkan.VkDeviceSize) size;

    Vulkan.vkCmdCopyBuffer(
        rhi.command_buffer,
        source_record.buffer,
        destination_record.buffer,
        1,
        *region,
    );

    if destination_record.access == .CPU_READ then make_gpu_writes_visible_to_cpu(rhi);
}

// Ends, submits, waits for, and consumes command_list.
submit :: (command_list: *Command_List) -> Result {
    rhi := usable_context();
    assert_command_list(rhi, command_list);
    defer consume_command_list(rhi, command_list);

    result := flush_cpu_writes(rhi);
    if result != .SUCCESS {
        discard_command_list(rhi);
        rhi.usable = false;
        return result;
    }

    vulkan_result := Vulkan.vkEndCommandBuffer(rhi.command_buffer);
    if vulkan_result != .SUCCESS {
        discard_command_list(rhi);
        rhi.usable = false;
        return result_from_vulkan(vulkan_result);
    }

    submit_info: Vulkan.VkSubmitInfo;
    {
        using submit_info;
        commandBufferCount = 1;
        pCommandBuffers    = *rhi.command_buffer;
    }

    vulkan_result = Vulkan.vkQueueSubmit(rhi.graphics_queue, 1, *submit_info, null);
    if vulkan_result != .SUCCESS {
        discard_command_list(rhi);
        rhi.usable = false;
        return result_from_vulkan(vulkan_result);
    }

    vulkan_result = Vulkan.vkQueueWaitIdle(rhi.graphics_queue);
    if vulkan_result != .SUCCESS {
        rhi.usable = false;
        return result_from_vulkan(vulkan_result);
    }

    vulkan_result = Vulkan.vkResetCommandPool(rhi.device, rhi.command_pool, 0);
    if vulkan_result != .SUCCESS {
        rhi.usable = false;
        return result_from_vulkan(vulkan_result);
    }

    clear_memory_uses(rhi);
    destroy_deferred_memory(rhi);

    return .SUCCESS;
}

gpu_offset :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    assert(offset >= 0, "JRHI GPU offset must not be negative. Add a byte offset of zero or greater.");

    address := cast(u64) pointer;
    result  := address + cast(u64) offset;

    assert(result >= address, "JRHI GPU pointer overflowed. Use a smaller offset.");
    return cast(GPU_Pointer) result;
}

operator + :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    return gpu_offset(pointer, offset);
}

operator - :: (pointer: GPU_Pointer, offset: s64) -> GPU_Pointer {
    assert(offset >= 0, "JRHI GPU offset must not be negative. Subtract a byte offset of zero or greater.");

    address         := cast(u64) pointer;
    offset_unsigned := cast(u64) offset;

    assert(offset_unsigned <= address, "JRHI GPU pointer underflowed. Subtract a smaller offset.");
    return cast(GPU_Pointer) (address - offset_unsigned);
}

// Returns a GPU pointer to a byte range inside memory.
gpu_at :: (memory: *Memory, offset: s64, size: s64) -> GPU_Pointer {
    // Unlike raw pointer arithmetic, this helper checks that the whole range is owned.
    assert(memory != null,               "JRHI memory does not exist. Pass a valid Memory pointer to JRHI.gpu_at.");
    assert(offset >= 0,                  "JRHI GPU offset must not be negative. Use a byte offset of zero or greater.");
    assert(size >= 0,                    "JRHI GPU range size must not be negative. Use a byte size of zero or greater.");
    assert(offset <= memory.size,        "JRHI GPU offset is outside its memory allocation. Use an offset within memory.");
    assert(size <= memory.size - offset, "JRHI GPU range is outside its memory allocation. Reduce size or choose a valid offset.");

    return gpu_offset(memory.gpu, offset);
}

#scope_file

// These flags describe which Vulkan objects must be destroyed during cleanup.
JRHI_Owned_Resources :: enum_flags u8 {
    NONE;             // No Vulkan object has been created.
    INSTANCE;         // instance must be destroyed.
    DEBUG_MESSENGER;  // debug_messenger must be destroyed before instance.
    DEVICE;           // device and every live Memory allocation must be destroyed.
    COMMAND_POOL;     // command_pool and its command_buffer must be destroyed before device.
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
    deferred_memory:      [..] Memory_Record;                // Memory waiting for the active command list to finish.
    instance:             Vulkan.VkInstance;                 // Connection to the Vulkan implementation.
    debug_messenger:      Vulkan.VkDebugUtilsMessengerEXT;   // Validation message callback, when enabled.
    validation_enabled:   bool;                              // Whether the validation layer was created.
    physical_gpu:         Vulkan.VkPhysicalDevice;           // GPU selected for this context.
    device:               Vulkan.VkDevice;                   // Logical device used to allocate and submit work.
    graphics_queue:       Vulkan.VkQueue;                    // The one graphics queue currently exposed.
    graphics_queue_index: u32;                               // Family index of graphics_queue.
    command_pool:         Vulkan.VkCommandPool;              // Owns the internal Vulkan command buffer.
    command_buffer:       Vulkan.VkCommandBuffer;            // Records the active Command_List.
    active_command_list:  u64;                               // Nonzero while command_buffer is recording.
    next_command_list:    u64;                               // Generates nonzero Command_List tokens.
    usable:               bool;                              // False after a failed submission; only destroy is then allowed.
}

Memory_Record :: struct {
    gpu:              GPU_Pointer;            // Key used to find this record during free.
    buffer:           Vulkan.VkBuffer;        // Buffer that gives the allocation its GPU address.
    device_memory:    Vulkan.VkDeviceMemory;  // Vulkan memory bound to buffer.
    size:             s64;                    // Requested byte count, not Vulkan's aligned allocation size.
    access:           Memory_Access;          // CPU mapping direction selected at allocation.
    host_is_coherent: bool;                   // False means CPU cache management is required.
    owned_resources:  Memory_Owned_Resources; // Handles that need cleanup after partial creation.
    recording_command_list: u64;              // Active command list that currently references this memory.

    // @Priority:
    // Replace individual Vulkan allocations with heap suballocation.
    // Keep deferred frees alive across asynchronous GPU submissions.
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

usable_context :: () -> *JRHI_Context {
    rhi := current();
    assert(
        rhi.usable,
        "JRHI context cannot be used after a failed submission. Call JRHI.destroy(), then create a new JRHI context."
    );
    return rhi;
}

assert_command_list :: (rhi: *JRHI_Context, command_list: *Command_List) {
    assert(command_list != null, "JRHI command list does not exist. Pass the Command_List returned by JRHI.begin_command_list.");
    assert(cast(u64) command_list.* != 0, "JRHI command list was already submitted. Start a new list with JRHI.begin_command_list.");
    assert(cast(u64) command_list.* == rhi.active_command_list, "JRHI command list is not recording. Record commands before submitting it.");
}

consume_command_list :: (rhi: *JRHI_Context, command_list: *Command_List) {
    rhi.active_command_list = 0;
    command_list.* = 0;
}

// Drops unsubmitted commands and releases their recorded memory references.
discard_command_list :: (rhi: *JRHI_Context) {
    vulkan_result := Vulkan.vkResetCommandPool(rhi.device, rhi.command_pool, 0);
    if vulkan_result != .SUCCESS {
        rhi.usable = false;
        return;
    }

    clear_memory_uses(rhi);
    destroy_deferred_memory(rhi);
}

memory_record :: (rhi: *JRHI_Context, memory: *Memory) -> *Memory_Record {
    record := table_find_pointer(*rhi.memory_records, memory.gpu);
    assert(record != null, "JRHI memory is not allocated or was already freed. Use the Memory returned by JRHI.alloc.");
    return record;
}

mark_memory_used :: (rhi: *JRHI_Context, record: *Memory_Record) {
    record.recording_command_list = rhi.active_command_list;
}

clear_memory_uses :: (rhi: *JRHI_Context) {
    for * record: rhi.memory_records {
        if record.recording_command_list == rhi.active_command_list {
            record.recording_command_list = 0;
        }
    }
}

destroy_deferred_memory :: (rhi: *JRHI_Context) {
    for record: rhi.deferred_memory {
        destroy_memory_record(rhi, *record);
    }

    array_reset_keeping_memory(*rhi.deferred_memory);
}

aligned_memory_offset :: (rhi: *JRHI_Context, offset: s64) -> Vulkan.VkDeviceSize {
    properties: Vulkan.VkPhysicalDeviceProperties;
    Vulkan.vkGetPhysicalDeviceProperties(rhi.physical_gpu, *properties);

    atom_size := cast(s64) properties.limits.nonCoherentAtomSize;
    return cast(Vulkan.VkDeviceSize) (offset - offset % atom_size);
}

flush_cpu_writes :: (rhi: *JRHI_Context) -> Result {
    for * record: rhi.memory_records {
        if record.recording_command_list != rhi.active_command_list then continue;
        if record.access != .CPU_WRITE || record.host_is_coherent then continue;

        range: Vulkan.VkMappedMemoryRange;
        range.memory = record.device_memory;
        range.offset = 0;
        range.size   = Vulkan.VK_WHOLE_SIZE;

        vulkan_result := Vulkan.vkFlushMappedMemoryRanges(rhi.device, 1, *range);
        if vulkan_result != .SUCCESS then return result_from_vulkan(vulkan_result);
    }

    return .SUCCESS;
}

// Makes preceding transfer writes available to a later CPU read.
make_gpu_writes_visible_to_cpu :: (rhi: *JRHI_Context) {
    barrier: Vulkan.VkMemoryBarrier;
    barrier.srcAccessMask = .TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = .HOST_READ_BIT;

    Vulkan.vkCmdPipelineBarrier(
        rhi.command_buffer,
        .TRANSFER_BIT,
        .HOST_BIT,
        0,
        1,
        *barrier,
        0,
        null,
        0,
        null,
    );
}

result_from_vulkan :: (result: Vulkan.VkResult) -> Result {
    if result == .SUCCESS {
        return .SUCCESS;
    }

    if result == .ERROR_OUT_OF_HOST_MEMORY || result == .ERROR_OUT_OF_DEVICE_MEMORY {
        return .OUT_OF_MEMORY;
    }

    return .FAILED;
}

choose_memory_type :: (
    rhi: *JRHI_Context,
    memory_type_bits: u32,
    access: Memory_Access,
) -> bool, u32, bool {
    // Read the memory heaps and memory types exposed by the chosen GPU.
    memory_properties: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(rhi.physical_gpu, *memory_properties);

    best_score: s32 = -1;
    best_index: u32;
    best_is_coherent := false;

    for memory_type, index: memory_properties.memoryTypes {
        if index >= memory_properties.memoryTypeCount then break;

        memory_type_bit: u32 = cast(u32) 1 << cast(u32) index;
        if !(memory_type_bits & memory_type_bit) then continue;

        is_host_visible := (memory_type.propertyFlags & .HOST_VISIBLE_BIT)  != 0;
        is_coherent     := (memory_type.propertyFlags & .HOST_COHERENT_BIT) != 0;
        is_cached       := (memory_type.propertyFlags & .HOST_CACHED_BIT)   != 0;
        is_device_local := (memory_type.propertyFlags & .DEVICE_LOCAL_BIT)  != 0;

        if access != .GPU_ONLY && !is_host_visible then continue;

        score: s32;
        if access == .GPU_ONLY {
            if is_device_local  then score += 2;
            if !is_host_visible then score += 1;
        } else if access == .CPU_WRITE {
            if is_coherent     then score += 2;
            if is_device_local then score += 1;
        } else {
            if is_cached       then score += 2;
            if is_coherent     then score += 1;
            if is_device_local then score += 1;
        }

        if score > best_score {
            best_score       = score;
            best_index       = cast(u32) index;
            best_is_coherent = is_coherent;
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

create_command_list_storage :: (rhi: *JRHI_Context) -> Result {
    pool_info: Vulkan.VkCommandPoolCreateInfo;
    pool_info.queueFamilyIndex = rhi.graphics_queue_index;

    vulkan_result := Vulkan.vkCreateCommandPool(rhi.device, *pool_info, null, *rhi.command_pool);
    if vulkan_result != .SUCCESS then return result_from_vulkan(vulkan_result);
    rhi.owned_resources |= .COMMAND_POOL;

    allocate_info: Vulkan.VkCommandBufferAllocateInfo;
    {
        using allocate_info;
        commandPool        = rhi.command_pool;
        level              = .PRIMARY;
        commandBufferCount = 1;
    }

    vulkan_result = Vulkan.vkAllocateCommandBuffers(rhi.device, *allocate_info, *rhi.command_buffer);
    if vulkan_result != .SUCCESS then return result_from_vulkan(vulkan_result);

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
        if rhi.usable {
            vulkan_result := Vulkan.vkDeviceWaitIdle(rhi.device);
            if vulkan_result != .SUCCESS {
                log("JRHI could not wait for GPU work to finish while destroying the context.");
            }
        }
        if rhi.owned_resources & .COMMAND_POOL {
            Vulkan.vkDestroyCommandPool(rhi.device, rhi.command_pool, null);
        }
        destroy_live_memory_records(rhi);
        destroy_deferred_memory(rhi);
        Vulkan.vkDestroyDevice(rhi.device, null);
    }

    if rhi.owned_resources & .INSTANCE {
        Vulkan.vkDestroyInstance(rhi.instance, null);
    }

    array_reset(*rhi.deferred_memory);

    // Return the private context through the allocator that created it.
    free(rhi,, rhi.allocator);
}
