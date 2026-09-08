// MIT License - Copyright (c) 2022 Hamad Almamari
// Tested with vulkan 1.0 and 1.2
// You can use this file to generate any version of vulkan bindings.
// You only need to set the vulkan.h and vulkan lib paths.

// config
AT_COMPILE_TIME   :: true;
vulkan_h_location :: "source/vulkan.h";




#if AT_COMPILE_TIME {
	#run,stallable {
		set_build_options_dc(.{do_output=false});
		if !generate_bindings() {
			compiler_set_workspace_status(.FAILED);
		}
	}
} else {
	#import "System";

	main :: () {
		set_working_directory(path_strip_filename(get_path_of_running_executable()));
		if !generate_bindings() {
			exit(1);
		}
	}
}

//--------------------

OMIT_LIST :: string.[
	// These are defined manually:
	"VK_NULL_HANDLE",
	"VK_TRUE",
	"VK_FALSE",
	"VK_WHOLE_SIZE",
	"VK_ATTACHMENT_UNUSED",
	"VK_QUEUE_FAMILY_IGNORED",
	"VK_REMAINING_ARRAY_LAYERS",
	"VK_REMAINING_MIP_LEVELS",
	"VK_SUBPASS_EXTERNAL",
	"VK_MAX_PHYSICAL_DEVICE_NAME_SIZE",
	"VK_UUID_SIZE",
	"VK_MAX_MEMORY_TYPES",
	"VK_MAX_MEMORY_HEAPS",
	"VK_MAX_EXTENSION_NAME_SIZE",
	"VK_MAX_DESCRIPTION_SIZE",
	// Vulkan 1.3 functions that exist on Linux but are not part of our Windows version:
	"vkGetPhysicalDeviceSurfaceCapabilities2KHR",
	"vkGetPhysicalDeviceSurfaceFormats2KHR",
	// We use the definition from the Metal module
	"CAMetalLayer",
];

// These will be marked as #type,isa (means that it can be implicitely converted to its base type)
ISA_TYPE_LIST :: string.[
	"VkDeviceAddress",
];

generate_bindings :: () -> bool {
	output_filename: string;
	options: Generate_Bindings_Options;
	{
		using options;

		vulkan_sdk_path := to_string(getenv("VULKAN_SDK"));
		if !vulkan_sdk_path then assert(false, "Could not read the VULKAN_SDK env var");

		#if OS == .WINDOWS {
			// Copy the vulkan lib in this repo
			make_directory_if_it_does_not_exist("windows");
			copy_file(tprint("%\\Lib\\vulkan-1.lib", vulkan_sdk_path), "windows\\vulkan-1.lib");

			array_add(*libraries, .{filename="vulkan-1", identifier="libvulkan"});
			array_add(*extra_clang_arguments, "-x", "c", "-DWIN32_LEAN_AND_MEAN");
			array_add(*library_search_paths, "windows");

			output_filename  = "generated_windows.jai";
		} else #if OS == .LINUX {
			make_directory_if_it_does_not_exist("linux");
			copy_file(tprint("%/lib/libvulkan.so.1", vulkan_sdk_path), "linux/libvulkan.so.1");

			array_add(*libraries, .{filename="libvulkan.so.1", identifier="libvulkan"});
			array_add(*library_search_paths, "linux");
			output_filename  = "generated_linux.jai";
		} else #if OS == .MACOS {
			// Copy the vulkan lib in this repo
			make_directory_if_it_does_not_exist("macos");
			// The source file is a symlink, but this will follow the symlink
			copy_file(tprint("%/lib/libvulkan.1.dylib", vulkan_sdk_path), "macos/libvulkan.1.dylib");

			array_add(*libraries, .{filename="libvulkan.1.dylib", identifier="libvulkan"});
			array_add(*extra_clang_arguments, "-DVK_USE_PLATFORM_METAL_EXT=1", "-DVK_ENABLE_BETA_EXTENSIONS=1", "-DVK_USE_PLATFORM_MACOS_MVK=1");
			array_add(*library_search_paths, "macos");

			output_filename  = "generated_macos.jai";
		} else {
			assert(false);
		}

		array_add(*include_paths, tprint("%/include", vulkan_sdk_path));
		array_add(*source_files, "vulkan/vulkan.h");

		generate_library_declarations = true;

		visitor     = vulkan_visitor;
		log_stripped_declarations = false;
		generate_compile_time_struct_checks = false;
	}

	init_string_builder(*enumeration_wrapper_builder);

	bindings_builder, success := generate_bindings(options, log_results = true);
	if !success return false;

	append(*bindings_builder, "\n#import \"Basic\";\n\n#scope_export\n\n// Enumeration helpers\n\n");
	append_and_steal_buffers(*bindings_builder, *enumeration_wrapper_builder);

	success = write_entire_file(output_filename, *bindings_builder);
	if !success {
		log_error("Could not write generated output to \"%\"", output_filename);
		return false;
	}
	log("\nOK! generated '%'", output_filename);
	return true;
}

available_flag_bits: Table(string, *Enum);
struct_type_decl: *Enum;

enumeration_wrapper_builder: String_Builder;

vulkan_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
	// Omit header definitions (ex: VULKAN_H_)
	if decl.kind == .MACRO_DEFINITION && ends_with(decl.name, "_H_") {
		// print("MACRO_DEFINITION removed: %\n", decl.name);
		decl.decl_flags |= .OMIT_FROM_OUTPUT;
		return .STOP;
	}

	// Omit our OMIT_LIST
	if !parent_decl && array_find(OMIT_LIST, decl.name) {
		//print("OMIT_LIST: %\n", decl.name);
		decl.decl_flags |= .OMIT_FROM_OUTPUT;
		return .STOP;
	}

	if decl.kind == .TYPEDEF && array_find(ISA_TYPE_LIST, decl.name) {
		typedef := cast(*Typedef)decl;
		typedef.flags |= .ISA;
		return .STOP;
	}

	if decl.kind == .ENUM {
		en := cast(*Enum)decl;
		if en.name == "VkStructureType" {
			struct_type_decl = en; // Save for later
		}

		// Almost all enums should be unsigned
		if en.type && decl.name != "VkResult" {
			if en.type.size == {
				case 1;
					en.type = context.generator.type_def_u8;
				case 2;
					en.type = context.generator.type_def_u16;
				case 4;
					en.type = context.generator.type_def_u32;
				case 8;
					en.type = context.generator.type_def_u64;
			}
		}

		if contains(decl.name, "FlagBits") {
			en.flags |= .IS_ENUM_FLAGS;
			en.flags |= .VALUES_IN_HEX;

			// Remember this so we can replace the generic VkFlags aliases with the actual enum_flag's type below. :VkFlags
			table_add(*available_flag_bits, decl.name, en);
		}
	}

	// Replace typedef which has "VkFlags" as value. :VkFlags
	// VkAccessFlags :: VkFlags   ->   VkAccessFlags :: VkAccessFlagBits;
	// We don't change the name of the FlagBits enum directly because both the ...FlagBits and the ...Flags aliases are used in declarations.
	if decl.kind == .TYPEDEF && decl.type.type_of_typedef &&  decl.type.type_of_typedef.name == "VkFlags" {
		flags_name := replace(decl.name, "Flags", "FlagBits");
		found, enum_decl := table_find(*available_flag_bits, flags_name);
		if found {
			type := New(CType);
			type.type_of_enum = enum_decl;
			type.size = enum_decl.type.size;
			decl.type = type;
		}
	}

	// Set the default value for sType.
	if parent_decl && parent_decl.kind == .STRUCT && parent_decl.name != "VkBaseInStructure" && parent_decl.name != "VkBaseOutStructure" &&
			decl.kind == .DECLARATION && decl.name == "sType" {

		enum_value_name := get_sType_default_value_from_struct_name(parent_decl.name);
		enum_value: *Declaration;
		for struct_type_decl.enumerates {
			if it.output_name == enum_value_name {
				enum_value = it;
				break;
			}
		}

		if enum_value {
			literal := New(Literal);
			literal.literal_kind = .ENUM;
			literal.enum_type = struct_type_decl;
			literal.enum_value = enum_value;
			decl.expression = literal;
		} else {
			log_error("Could not find VkStructType enum value for %, the enum value name we tried was %", parent_decl.name, enum_value_name);
		}
	}

	if decl.kind == .FUNCTION {
		function := cast(*Function) decl;
		maybe_add_enumeration_wrapper(*enumeration_wrapper_builder, function);
	}

	return .RECURSE;
}

// @Cleanup: Jai modules now prefer to return errors in first slot, but this returns the VkResult second.
maybe_add_enumeration_wrapper :: (builder: *String_Builder, function: *Function) {
	if function.decl_flags & .OMIT_FROM_OUTPUT return;

	func_type := function.type.type_of_function;
	assert(func_type != null);

	if func_type.arguments.count < 2 return;

	count_arg := func_type.arguments[func_type.arguments.count - 2];
	data_arg := func_type.arguments[func_type.arguments.count - 1];

	// Make sure that the count is a *u32, that data is a pointer and that the return values is a VkResult (if present)
	if count_arg.type.pointer_to != context.generator.type_def_u32 return;
	if !data_arg.type.pointer_to return;
	assert(func_type.return_type != null);
	has_return_value := (func_type.return_type != context.generator.type_def_void);
	if has_return_value && get_type_name(func_type.return_type) != "VkResult" return;

	print_to_builder(builder, "% :: (", function.name);

	for i: 0..func_type.arguments.count - 3 {
		if i append(builder, ", ");
		arg := func_type.arguments[i];
		print_to_builder(builder, "%: ", arg.name);
		print_type_to_builder(builder, arg.type, null);
	}

	append(builder, ") -> [] ");
	print_type_to_builder(builder, data_arg.type.pointer_to, null);

	if has_return_value {
		append(builder, ", VkResult");
	}

	append(builder, " {\n");
	append(builder, "    count: u32;\n    data: [] ");
	print_type_to_builder(builder, data_arg.type.pointer_to, null);
	append(builder, ";\n");

	if has_return_value {
		append(builder, "    result: VkResult;\n");
	}

	print_call :: () #expand {
		append(builder, "    ");
		if has_return_value {
			append(builder, "result = ");
		}

		print_to_builder(builder, "%(", function.name);

		for 0..func_type.arguments.count - 3 {
			arg := func_type.arguments[it];
			print_to_builder(builder, "%, ", arg.name);
		}

		append(builder, "*count, data.data);\n");
	}

	print_call();

	if has_return_value {
		append(builder, "    if result return .[], result;\n");
	}

	append(builder, "    if count == 0 return .[]");
	if has_return_value {
		append(builder, ", .SUCCESS");
	}
	append(builder, ";\n");

	append(builder, "    data = NewArray(count, ");
	print_type_to_builder(builder, data_arg.type.pointer_to, null);
	append(builder, ", initialized = false);\n");

	print_call();

	append(builder, "    return data");
	if has_return_value {
		append(builder, ", result");
	}
	append(builder, ";\n}\n\n");
}

get_sType_default_value_from_struct_name :: (name: string) -> string {
	assert(name.count >= 3);

	is_upper :: (byte: u8) -> bool {
		if byte >= #char "A" && byte <= #char "Z" return true;
		return false;
	}

	is_num :: (byte: u8) -> bool {
		if byte >= #char "0" && byte <= #char "9" return true;
		return false;
	}

	matches :: (name: string, start: s64, target: string) -> bool {
		if start < 0 || start + target.count > name.count return false;
		return slice(name, start, target.count) == target;
	}

	builder: String_Builder;
	append(*builder, name[2]);

	for i: 3..name.count-1 {
		c := name[i];

		if is_upper(c) {
			is_first_uppercase := !is_upper(name[i-1]);
			is_end_of_uppercase_word := i != name.count-1 && !is_upper(name[i+1]);
			at_word_boundary := is_first_uppercase || is_end_of_uppercase_word;

			is_known_exception := at_word_boundary && (
				(is_num(name[i-1]) && matches(name, i, "BitStorage")) ||
				(i >= 14 && matches(name, i - 1, "AV1")) ||
				(i >= 14 && matches(name, i - 1, "VP9")) ||
				(c == #char "A" && i == 19 && matches(name, i - 3, "RGB")) ||
				(c == #char "X" && i == 22 && matches(name, i - 6, "RGBA10")) ||
				(i == 22 && matches(name, i - 6, "Float8")) ||
				(c == #char "D" && i >= 2 && (name[i-1] == #char "2" || name[i-1] == #char "3")) ||
				(c == #char "O" && matches(name, i - 3, "MacOS"))||
				matches(name, i - 3, "ASTC"));

			if at_word_boundary && !is_known_exception {
				append(*builder, #char "_");
			} else if matches(name, i - 4, "AABB") {
				append(*builder, #char "_");
			} else if i == 38 && matches(name, i - 4, "ASTC") {
				append(*builder, #char "_");
			}

			append(*builder, c);

		} else if is_num(c) {
			stays_glued :=
				(i >= 17 && matches(name, i + 1, "Bit")) ||
				(i >= 27 && (matches(name, i - 4, "Int")  || matches(name, i - 3, "Int"))) ||
				(i >= 29 && (matches(name, i - 4, "Uint") || matches(name, i - 5, "Uint"))) ||
				(i >= 27 && c != #char "2" && (matches(name, i - 5, "Float") || matches(name, i - 6, "Float"))) ||
				(i >= 27 && i + 1 < name.count && is_num(name[i+1]) &&
					(matches(name, i - 6, "Bfloat") || matches(name, i - 7, "Bfloat")))||
				(i >= 20 && (matches(name, i - 4, "RGBA") || matches(name, i - 6, "RGBA")))||
				(i >= 23 && matches(name, i - 7, "RGBA10X"))||
				(i >= 14 && (name[i-1] == #char "H" || name[i-2] == #char "H" || name[i-3] == #char "H")) ||
				(i >= 15 && matches(name, i - 2, "AV"))||
				(i >= 15 && matches(name, i - 2, "VP"))||
				(is_num(name[i-1]) && !(i >= 22 && (matches(name, i - 6, "Vulkan") || matches(name, i - 7, "Vulkan"))));

			if !stays_glued append(*builder, #char "_");
			append(*builder, c);

		} else {
			append(*builder, to_upper(c));
		}
	}

	return builder_to_string(*builder);
}

#scope_file
#import "Basic";
#import "Compiler";
#import "Check";
#import "Bindings_Generator";
#import "File";
#import "File_Utilities";
#import "String";
#import "Hash_Table";
#if OS == .WINDOWS {
	#import "Windows";
}  else {
	#import "POSIX";
}

sdk_error_and_quit :: () {
	write_string("Vulkan SDK not found. Please ensure that it's installed on your system!\n", true);
	exit(1);
}
