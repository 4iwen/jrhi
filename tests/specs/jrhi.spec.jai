#import,file "../../module.jai";

can_create_and_destroy :: () {
    result := create(application_name = "Create and Destroy Test");
    assert_that(result, is(Result.SUCCESS));

    if result == .SUCCESS then destroy();
} @Test

can_create_with_optional_validation :: () {
    result := create(
        application_name = "Optional Validation Test",
        validation       = .OPTIONAL,
    );
    assert_that(result, is(Result.SUCCESS));

    if result == .SUCCESS then destroy();
} @Test

requires_validation_layer_when_requested :: () {
    result := create(
        application_name = "Required Validation Test",
        validation       = .REQUIRED,
    );
    assert_that(result == .SUCCESS || result == .UNSUPPORTED, is(true));

    if result == .SUCCESS then destroy();
} @Test

can_create_after_destroy :: () {
    first_result := create(application_name = "First Lifecycle Test");
    assert_that(first_result, is(Result.SUCCESS));
    if first_result != .SUCCESS then return;
    destroy();

    second_result := create(application_name = "Second Lifecycle Test");
    assert_that(second_result, is(Result.SUCCESS));
    if second_result == .SUCCESS then destroy();
} @Test
