#import "Basic";

JRHI :: #import,file "../module.jai";

main :: () {
    result := JRHI.create(
        application_name = "JRHI Triangle",
        validation       = .OPTIONAL,
    );
    if result != .SUCCESS {
        log("Could not create JRHI: %.", result);
        return;
    }
    defer JRHI.destroy();

    log("JRHI is ready.");
}
