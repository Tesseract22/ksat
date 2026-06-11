package main

RECORDS_PATH :: "records.txt"
TASKS_PATH :: "tasks.txt"

Id :: u32
Task :: struct {
    name: string,
    children: [dynamic]Id,
    parent: Maybe(Id),
}

fatal :: proc(format: string, args: ..any) -> ! {
    fmt.print("fatal: ")
    fmt.printfln(format, ..args)
    os.exit(1)
}

read_tasks :: proc(file: ^os.File) -> (tasks: [dynamic]Task, task_map: map[string]Id, err: os.Error) {
    content := read_all(file) or_return
    idx : Id = 0
    for line_bytes in bytes.split_iterator(&content, {'\n'}) {
	line := string(line_bytes)
	name, success := strings.split_iterator(&line, ",")
	if !success {
	    fatal("CORRUPT TASK")
	}
	parent_id_str, success2 := strings.split_iterator(&line, ",")
	if !success2 {
	    fatal("CORRUPT TASK")
	}
	maybe_parent_id, success3 := strconv.parse_i64(parent_id_str, 10)
	if !success3 {
	    fatal("CORRUPT TASK")
	}
	if name in task_map {
	    fmt.printfln("error: duplicate task %s", name)
	} else {
	    task_map[name] = idx
	}
	parent_id : Maybe(Id) = nil
	if maybe_parent_id >= 0 {
	    parent_id = cast(u32) maybe_parent_id
	    if auto_cast maybe_parent_id >= len(tasks) {
		fatal("unknwon id `%v` for parent, parent must be declared before child", parent_id)
	    }
	    append(&tasks[maybe_parent_id].children, idx)
	}
	append(&tasks, Task {name, {}, auto_cast parent_id})
	idx += 1
    }
    return
}

read_all :: proc(file: ^os.File) -> ([]u8, os.Error) {
    res : [dynamic]u8
    buf := make([]u8, 256)
    os.seek(file, 0, .Start)
    for {
	n, err := os.read(file, buf)
	if err == .EOF {
	    break
	} else if err != nil {
	    return nil, err
	}
	append_elems(&res, ..buf[0:n])
    }
    return res[:], nil
}

Record :: struct {
    start: Time,
    end: Time,
    task: Id,
}

Record_serialize :: proc(f: ^os.File, record: Record) -> os.Error {
    fmt.fprintf(f, "%v,", time.time_to_unix_nano(record.start))
    fmt.fprintf(f, "%v,", time.time_to_unix_nano(record.end))
    fmt.fprintf(f, "%v\n", record.task)

    return nil
}

Record_deserialize :: proc(buf: ^[]u8) -> (record: Record, rest: []u8, success: bool) {
    if len(buf) == 0 do return
    newline_idx := bytes.index_byte(buf^, '\n');
    if newline_idx < 0 {
	log.error("record must end in a newline")
	return
    }
    line := buf[:newline_idx]
    rest = buf[newline_idx+1:]
    buf^ = rest
    success = true
    comp_idx := 0
    for comp in bytes.split_iterator(&line, {','}) {
	switch comp_idx {
	    case 0:
		start_nano, success := strconv.parse_i64(auto_cast comp, 10)
		if !success {
		    log.error("cannot parse start time")
		    return
		}
		record.start = time.from_nanoseconds(start_nano)
	    case 1:
		end_nano, success := strconv.parse_i64(auto_cast comp, 10)
		if !success {
		    log.error("cannot parse end time")
		    return
		}
		record.end = time.from_nanoseconds(end_nano)
	    case 2:
		task, success := strconv.parse_u64(auto_cast comp, 10)
		if !success {
		    log.error("cannot parse task")
		    return
		}
		record.task = auto_cast task
	    case:
		log.error("extra field")
		return


	}
	comp_idx += 1
    }
    if comp_idx < 3 {
	log.errorf("expect more field, got %v", comp_idx)
	return
    }
    return
}

Duration_pprint :: proc(d: time.Duration) {
    hour := i64(d/time.Hour)
    min := i64((d%time.Hour)/time.Minute)
    if hour > 0 {
	fmt.printf("%vh", hour)
    }
    if hour > 0 || min > 0 {
	fmt.printf("%vm", min)
    }
}

Record_pprint :: proc(record: Record, tasks: [dynamic]Task, region: ^datetime.TZ_Region) {
    Time_pprint :: proc(t: Time, region: ^datetime.TZ_Region) {
	dt_utc, success := time.time_to_datetime(t)
	assert(success)
	dt := tz.datetime_to_tz(dt_utc, region)
	fmt.printf("%2v/%2v, %2v:%2v", dt.month, dt.day, dt.hour, dt.minute)
    }

    if cast(int) record.task >= len(tasks) {
	fmt.printf("%unknown task(5i): ", record.task)
    } else {
	fmt.printf("%-20s: ", tasks[record.task].name)
    }

    Time_pprint(record.start, region)
    fmt.print(" => ")
    Time_pprint(record.end, region)
    fmt.print(" ")

    duration := time.diff(record.start, record.end)
    Duration_pprint(duration)

    fmt.println()
}

Command :: enum {
    None = 0,
    start,
    list,
    new,
    rm,
    tasks,
    help
}

Task_Id_Name :: union { Id, string }

Options :: struct {
    command: Command,
    task: Task_Id_Name,
    parent: Task_Id_Name,
}
parse_cli_args :: proc() -> (opts: Options, success := true) {
    shift_args :: proc(args: ^[]string) -> (string, bool) {
	if len(args) == 0 do return "", false
	first := args[0]
	args^ = args[1:]
	return first, true
    }
    args := os.args
    prog_name, _ := shift_args(&args)
    command: string = ""

    print_subs :: proc() {
	fmt.println("subcommands:")
	fmt.println("  start    starts recording")
	fmt.println("  list     list records")
	fmt.println("  new      add a new task")
	fmt.println("  rm       remove a task")
	fmt.println("  tasks    list tasks")
	fmt.println("  help     print help message (for a specific command)")
    }
    print_help_for_sub :: proc(sub: Command) {
	fmt.printf("expect: %s", sub)
	switch sub {
	case .None: log.assert(false)
	case .start:
	    fmt.println(" <task>")
	case .list:
	    fmt.println(" [-t/--task <task>]")
	case .rm:
	    fmt.println(" <task_name>")
	case .new:
	    fmt.println(" <task_name> [-p/--parent <task>]")
	case .tasks:
	case .help:
	    fmt.println(" [<subcommand>]")
	}
    }
    parse_task_id_or_name :: proc(task_str: string) -> Task_Id_Name {
	if task_u64, parse_success := strconv.parse_u64(task_str); !parse_success {
	    return task_str
	} else {
	    return cast(Id) task_u64
	}
    }
    expect_task_after :: proc(args: ^[]string, before: string) -> Task_Id_Name {
	if task_str, success := shift_args(args); !success {
	    fatal("Expect <task> after %s", before)
	} else {
	    return parse_task_id_or_name(task_str)
	}
    }
    parse_subcommand :: proc "contextless" (arg: string) -> Command {
	switch arg {
	case "start":
	    return .start
	case "list":
	    return .list
	case "new":
	    return .new
	case "rm":
	    return .rm
	case "tasks":
	    return .tasks
	case "help", "--help", "-h":
	    return .help
	case:
	    return .None
	}
    }

    defer if !success {
	if opts.command == .None {
	    print_subs()
	}
	else {
	    print_help_for_sub(opts.command)
	}
    }
    defer if len(args) > 0 {
	    fatal("unrecognized extra args starting at `%s`", args[0])
	}

    if command, success = shift_args(&args); !success {
	fmt.println("error: Expect subcommand")
	return
    }

    opts.command = parse_subcommand(command)

    switch opts.command {
    case .start:
	opts.task = expect_task_after(&args, "start")
    case .list:
	for arg in shift_args(&args) {
	    switch arg {
	    case "--task", "-t":
		opts.task = expect_task_after(&args, arg)
	    case:
		fatal("Unknown argument")
	    }
	}
    case .new:
	opts.command = .new
	for arg in shift_args(&args) {
	    switch arg {
	    case "--parent", "-p":
		opts.parent = expect_task_after(&args, arg)
	    case:
		if opts.task != nil {
		    fmt.printfln("error: Extra positional arg `%s`", arg)
		    return
		}
		opts.task = arg
	    }
	}
    case .rm:
	opts.command = .rm
	opts.task = expect_task_after(&args, "start")
    case .tasks:
	opts.command = .tasks
    case .help:
	success = false
	if help_sub, success := shift_args(&args); !success {
	    opts.command = .None
	} else {
	    opts.command = parse_subcommand(help_sub)
	}
	return
    case .None:
	fmt.printfln("error: Unknown subcommand `%s`", command)
	success = false
	return
    }
    return
}

task_get_id :: proc(task: Task_Id_Name, tasks: [dynamic]Task, task_map: map[string]Id) -> (task_id: Id) {
    switch data in task {
    case Id: {
	if cast(int) data >= len(tasks) {
	    fatal("unknown task id %v", data)
	}
	task_id = data
    }
    case string:
	if !(data in task_map) {
    	    fatal("unknown task name %v", data)
    	}
	task_id = task_map[data]
    }
    return
}

task_tree_pprint :: proc(tasks: [dynamic]Task) {
    print :: proc(tasks: [dynamic]Task, node: Task, depth: u32) {
	for _ in 0..<4*depth {
	    fmt.print(" ")
	}
	fmt.printfln("|-- %s", node.name)
	for child in node.children {
	    print(tasks, tasks[child], depth + 1)
	}
    }
    for task in tasks {
	if task.parent == nil {
	    print(tasks, task, 0)
	}
    }
}

main :: proc() {
    context.logger = log.create_console_logger()

    opts, success := parse_cli_args();
    if !success do return

    f, err := os.open(RECORDS_PATH, {.Read, .Write, .Create, .Append})
    if err != nil {
	fmt.printf("cannot open %v: %v\n", RECORDS_PATH, err)
	return
    }
    defer os.close(f)
    task_f, err1 := os.open(TASKS_PATH, {.Read, .Write, .Create, .Append})
    if err1 != nil {
	fmt.printf("cannot open %v: %v", TASKS_PATH, err1)
	return
    }
    defer os.close(task_f)
    tasks, task_map, err2 := read_tasks(task_f)
    if err2 != nil {
	fmt.printf("cannot read tasks from %v: %v", TASKS_PATH, err2)
	return
    }

    region := tz.region_load("local") or_else {}

    switch opts.command {
    case .None:
	fallthrough
    case .help:
	log.assert(false)
    case .new:
	name := opts.task.(string)
	if _, success = strconv.parse_i64(name, 10); success {
	    fatal("task name cannot be numbers, got %v", name)
	}
	if name in task_map {
	    fatal("duplicate task %v", name)
	}
	parent_id : i64 = i64(task_get_id(opts.parent, tasks, task_map)) if opts.parent != nil else -1
	fmt.fprintfln(task_f, "%s,%i", name, parent_id)
    case .rm:
	task_name: string
	switch data in opts.task {
	case Id: {
	    if cast(int) data >= len(tasks) {
		fatal("unknown task id %v", data)
	    }
	    task_name = tasks[data].name
	}
	case string:
	    if !(data in task_map) {
	        fatal("unknown task name %v", data)
	    }
	    task_name = data
	}
	delete_key(&task_map, task_name)

	os.truncate(task_f, 0)
	for key in task_map {
	    fmt.fprintln(task_f, key)
	}
    case .start:
	task_id := task_get_id(opts.task, tasks, task_map)
	start := time.now()
	fmt.printfln("task `%s` starts at %v", opts.task, start)

	stdin := os.stdin
	buf := make([]u8, 16)
	wait: for {
	    n, err := os.read(stdin, buf)
	    if err != nil {
		break
	    }

	    slice := buf[:n]
	    for c in slice {
		if c == '\n' || c == '\r' do break wait
	    }
	}

	end := time.now()
	fmt.printfln("task `%s` ends at %v", opts.task, end)

	Record_serialize(f, { start, end, task_id })
    case .tasks:
	task_tree_pprint(tasks)
    case .list:
	content, err1 := read_all(f)
	if err1 != nil {
	    fmt.printf("cannot read %v: %v\n", RECORDS_PATH, err1)
	    return
	}
	task_id := task_get_id(opts.task, tasks, task_map)

	task_duration :map[Id]time.Duration
	for record in Record_deserialize(&content) {
	    if opts.task == nil || task_id == record.task {
		Record_pprint(record, tasks, region)

		duration := time.diff(record.start, record.end)
		if !(record.task in task_duration) {
		    task_duration[record.task] = 0
		}
		task_duration[record.task] += duration
	    }
	}

	fmt.println("\nstatistics:")
	for id, duration in task_duration {
	    name := tasks[id].name
	    fmt.printf("%-20s: ", name)
	    Duration_pprint(duration)
	    fmt.println()
	}
    }
}

import "core:os"
import "core:fmt"
import "core:bytes"
import "core:strings"
import "core:time"; Time :: time.Time
import tz "core:time/timezone"
import "core:time/datetime"
import "core:strconv"
import "core:log"
import "core:container/bit_array"

import "base:runtime"; Maybe :: runtime.Maybe

