JRHI :: #import,file "../../module.jai";

can_create_and_destroy :: () {
    result := JRHI.create(application_name = "Create and Destroy Test");
    assert_that(result, is(JRHI.Result.SUCCESS));

    if result == .SUCCESS then JRHI.destroy();
} @Test

can_create_with_optional_validation :: () {
    result := JRHI.create(
        application_name = "Optional Validation Test",
        validation       = .OPTIONAL,
    );
    assert_that(result, is(JRHI.Result.SUCCESS));

    if result == .SUCCESS then JRHI.destroy();
} @Test

requires_validation_layer_when_requested :: () {
    result := JRHI.create(
        application_name = "Required Validation Test",
        validation       = .REQUIRED,
    );
    assert_that(result == .SUCCESS || result == .UNSUPPORTED, is(true));

    if result == .SUCCESS then JRHI.destroy();
} @Test

can_create_after_destroy :: () {
    first_result := JRHI.create(application_name = "First Lifecycle Test");
    assert_that(first_result, is(JRHI.Result.SUCCESS));
    if first_result != .SUCCESS then return;
    JRHI.destroy();

    second_result := JRHI.create(application_name = "Second Lifecycle Test");
    assert_that(second_result, is(JRHI.Result.SUCCESS));
    if second_result == .SUCCESS then JRHI.destroy();
} @Test

can_allocate_cpu_write_memory :: () {
    create_result := JRHI.create(application_name = "JRHI Memory Test");
    assert_that(create_result, is(JRHI.Result.SUCCESS));
    if create_result != .SUCCESS then return;
    defer JRHI.destroy();

    memory, allocation_result := JRHI.alloc(64, access = .CPU_WRITE);
    assert_that(allocation_result, is(JRHI.Result.SUCCESS));
    if allocation_result != .SUCCESS then return;

    assert_that(memory.cpu != null, is(true));
    assert_that(cast(u64) memory.gpu != 0, is(true));
    assert_that(memory.size, is(64));

    bytes := cast(*u8) memory.cpu;
    bytes[0] = 0x5a;
    assert_that(bytes[0], is(0x5a));

    address := JRHI.gpu_at(*memory, 16, 16);
    assert_that(address, is(memory.gpu + 16));

    JRHI.free(*memory);
    assert_that(memory.cpu == null, is(true));
    assert_that(cast(u64) memory.gpu == 0, is(true));
    assert_that(memory.size == 0, is(true));

    gpu_memory, gpu_allocation_result := JRHI.alloc(64, access = .GPU_ONLY);
    assert_that(gpu_allocation_result, is(JRHI.Result.SUCCESS));
    if gpu_allocation_result != .SUCCESS then return;

    assert_that(gpu_memory.cpu == null, is(true));
    assert_that(cast(u64) gpu_memory.gpu != 0, is(true));
    JRHI.free(*gpu_memory);
} @Test

can_record_and_submit_fill :: () {
    create_result := JRHI.create(application_name = "JRHI Command List Test");
    assert_that(create_result, is(JRHI.Result.SUCCESS));
    if create_result != .SUCCESS then return;
    defer JRHI.destroy();

    memory, allocation_result := JRHI.alloc(64, access = .CPU_READ);
    assert_that(allocation_result, is(JRHI.Result.SUCCESS));
    if allocation_result != .SUCCESS then return;
    defer JRHI.free(*memory);

    command_list, begin_result := JRHI.begin_command_list();
    assert_that(begin_result, is(JRHI.Result.SUCCESS));
    if begin_result != .SUCCESS then return;

    JRHI.fill(*command_list, *memory, value = 0x44332211);

    submit_result := JRHI.submit(*command_list);
    assert_that(submit_result, is(JRHI.Result.SUCCESS));
    assert_that(cast(u64) command_list == 0, is(true));

    read_result := JRHI.read(*memory);
    assert_that(read_result, is(JRHI.Result.SUCCESS));
    values := cast(*u32) memory.cpu;
    assert_that(values.*, is(0x44332211));

    command_list, begin_result = JRHI.begin_command_list();
    assert_that(begin_result, is(JRHI.Result.SUCCESS));
    if begin_result != .SUCCESS then return;

    JRHI.fill(*command_list, *memory, offset = 0, size = 64, value = 0x44332211);

    submit_result = JRHI.submit(*command_list);
    assert_that(submit_result, is(JRHI.Result.SUCCESS));
    assert_that(cast(u64) command_list == 0, is(true));

    read_result = JRHI.read(*memory, offset = 0, size = 64);
    assert_that(read_result, is(JRHI.Result.SUCCESS));
    assert_that(values.*, is(0x44332211));
} @Test

can_copy_and_defer_free_memory :: () {
    create_result := JRHI.create(application_name = "JRHI Copy Test");
    assert_that(create_result, is(JRHI.Result.SUCCESS));
    if create_result != .SUCCESS then return;
    defer JRHI.destroy();

    source, source_result := JRHI.alloc(64, access = .CPU_WRITE);
    assert_that(source_result, is(JRHI.Result.SUCCESS));
    if source_result != .SUCCESS then return;

    destination, destination_result := JRHI.alloc(64, access = .CPU_READ);
    assert_that(destination_result, is(JRHI.Result.SUCCESS));
    if destination_result != .SUCCESS then return;
    defer JRHI.free(*destination);

    unrelated, unrelated_result := JRHI.alloc(64, access = .GPU_ONLY);
    assert_that(unrelated_result, is(JRHI.Result.SUCCESS));
    if unrelated_result != .SUCCESS then return;

    command_list, begin_result := JRHI.begin_command_list();
    assert_that(begin_result, is(JRHI.Result.SUCCESS));
    if begin_result != .SUCCESS then return;

    source_values := cast(*u32) source.cpu;
    source_values.* = 0x11223344;

    JRHI.copy(
        *command_list,
        destination        = *destination,
        destination_offset = 0,
        source             = *source,
        source_offset      = 0,
        size               = 64,
    );

    JRHI.free(*unrelated);
    assert_that(unrelated.size == 0, is(true));

    JRHI.defer_free(*command_list, *source);
    assert_that(source.size == 0, is(true));

    submit_result := JRHI.submit(*command_list);
    assert_that(submit_result, is(JRHI.Result.SUCCESS));
    assert_that(cast(u64) command_list == 0, is(true));

    read_result := JRHI.read(*destination, offset = 0, size = 4);
    assert_that(read_result, is(JRHI.Result.SUCCESS));
    destination_values := cast(*u32) destination.cpu;
    assert_that(destination_values.*, is(0x11223344));
} @Test
