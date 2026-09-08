#scope_file

#import "Basic";

#load "../modules/stubborn/run.jai";

#run {
    build_tests(
        get_build_options(),
        "./specs",
        module_paths = ".."
    );
}
