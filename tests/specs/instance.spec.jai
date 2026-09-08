#import,file "../../module.jai";

instance_can_be_created_and_destroyed :: () {
    descriptor: JRHI_Create_Descriptor;
    {
        using descriptor;
        application_name        = "jrhi tests";
        application_version     = .{0, 1, 0};
        engine_name             = "jrhi";
        engine_version          = .{0, 1, 0};
        enable_validation_layer = false;
    }

    ok := jrhi_create(descriptor);
    assert_that(ok, is(true));
    assert_that(context.jrhi != null, is(true));
    assert_that(context.jrhi.instance != null, is(true));

    jrhi_destroy();
    assert_that(context.jrhi == null, is(true));
} @Test
