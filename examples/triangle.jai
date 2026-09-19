#import "Basic";

JRHI :: #import,file "../module.jai";

Vertex :: struct {
    position: [2] float;
    color:    [3] float;
}

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

    // CPU data for one triangle. This is copied into GPU memory below.
    vertices: [3] Vertex = .[
        .{position = .[-0.5, -0.5], color = .[1.0, 0.0, 0.0]},
        .{position = .[ 0.5, -0.5], color = .[0.0, 1.0, 0.0]},
        .{position = .[ 0.0,  0.5], color = .[0.0, 0.0, 1.0]},
    ];

    // Allocate GPU memory for the triangle vertices.
    // memory.cpu lets the CPU write the allocation.
    // memory.gpu is the 64-bit address a shader will later use.
    memory, allocation_result := JRHI.alloc(size_of([3] Vertex));
    if allocation_result != .SUCCESS {
        log("Could not allocate triangle memory: %.", allocation_result);
        return;
    }
    defer JRHI.free(*memory);

    // Write the vertices through the CPU mapping.
    mapped_vertices := cast(*[3] Vertex) memory.cpu;
    mapped_vertices.* = vertices;

    // Get the start of this allocation as a GPU address.
    vertex_address := JRHI.gpu_at(*memory, 0, size_of([3] Vertex));
    log("Triangle vertices are at GPU address 0x%.", FormatInt.{
        value          = cast(u64) vertex_address,
        base           = 16,
        minimum_digits = 16,
    });
}
