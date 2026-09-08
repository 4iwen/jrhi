
#import "Basic";
#import,file "../module.jai";

main :: () {
    descriptor: JRHI_Create_Descriptor;
    {
        using descriptor;
        application_name        = "triangle";
        application_version     = .{0, 1, 0};
        engine_name             = "jrhi";
        engine_version          = .{0, 1, 0};
        enable_validation_layer = false;
    }

    ok := jrhi_create(descriptor);
    assert(ok, "Could not create Vulkan instance.");
    defer jrhi_destroy();

    log("Vulkan instance created.");
}
