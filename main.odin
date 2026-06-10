package main

RECORDS_PATH :: "records.txt"
TASKS_PATH :: "tasks.txt"

fatal :: proc(format: string, args: ..any) -> ! {
    fmt.print("fatal: ")
    fmt.printfln(format, ..args)
    os.exit(1)
}

read_tasks :: proc(file: ^os.File) -> (tasks: [dynamic]string, task_map: map[string]u32, err: os.Error) {
    content := read_all(file) or_return
    idx : u32 = 0
    for line in bytes.split_iterator(&content, {'\n'}) {
	str := string(line)
	append(&tasks, str)
	if str in task_map {
	    fmt.printfln("error: duplicate task %s", str)
	} else {
	    task_map[str] = idx
	}
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

Time :: time.Time

Record :: struct {
    start: Time,
    end: Time,
    task: u32,
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

Record_pprint :: proc(record: Record, tasks: [dynamic]string, region: ^datetime.TZ_Region) {
    Time_pprint :: proc(t: Time, region: ^datetime.TZ_Region) {
	dt_utc, success := time.time_to_datetime(t)
	assert(success)
	dt := tz.datetime_to_tz(dt_utc, region)
	fmt.printf("%2v/%2v, %2v:%2v", dt.month, dt.day, dt.hour, dt.minute)
    }

    if cast(int) record.task >= len(tasks) {
	fmt.printf("%unknown task(5i): ", record.task)
    } else {
	fmt.printf("%-20s: ", tasks[record.task])
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

Task :: union { u32, string }

Options :: struct {
    command: Command,
    task: Task,
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
	fmt.println("  start    Starts recording")
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
	case .rm:
	    fallthrough
	case .new:
	    fmt.println(" <task_name>")
	case .tasks:
	case .help:
	    fmt.println(" <subcommand>")
	}
    }
    parse_task_id_or_name :: proc(task_str: string) -> Task {
	if task_u64, parse_success := strconv.parse_u64(task_str); !parse_success {
	    return task_str
	} else {
	    return cast(u32) task_u64
	}
    }
    expect_task_after :: proc(args: ^[]string, before: string) -> Task {
	if task_str, success := shift_args(args); !success {
	    fatal("Expect <task> after %s", before)
	} else {
	    return parse_task_id_or_name(task_str)
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

    switch command {
	case "start":
	    opts.command = .start
	    opts.task = expect_task_after(&args, "start")
	case "list":
	    opts.command = .list
	    for arg in shift_args(&args) {
		switch arg {
		case "--task", "-t":
		    opts.task = expect_task_after(&args, arg)
		case:
		    fatal("Unknown argument")
		}
	    }
	case "new":
	    opts.command = .new
	    if opts.task, success = shift_args(&args); !success {
		fmt.println("error: Expect postional argument <task_name>")
		return
	    }
	case "rm":
	    opts.command = .rm
	    opts.task = expect_task_after(&args, "start")
	case "tasks":
	    opts.command = .tasks
	case "help", "--help", "-h":
	    //opts.command = .help
	    success = false
	    return
	case:
	    fmt.printfln("error: Unknown subcommand `%s`", command)
	    success = false
	    return
    }
    return
}

task_get_id :: proc(task: Task, tasks: [dynamic]string, task_map: map[string]u32) -> (task_id: u32) {
    switch data in task {
    case u32: {
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
	fmt.fprintln(task_f, name)
    case .rm:
	task_name: string
	switch data in opts.task {
	case u32: {
	    if cast(int) data >= len(tasks) {
		fatal("unknown task id %v", data)
	    }
	    task_name = tasks[data]
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
	for name, i in tasks {
	    fmt.printfln("%2i: %s", i, name)
	}
    case .list:
	content, err1 := read_all(f)
	if err1 != nil {
	    fmt.printf("cannot read %v: %v\n", RECORDS_PATH, err1)
	    return
	}
	task_id := task_get_id(opts.task, tasks, task_map)

	task_duration :map[u32]time.Duration
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
	for task, duration in task_duration {
	    name := tasks[task]
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
import "core:time"
import tz "core:time/timezone"
import "core:time/datetime"
import "core:strconv"
import "core:log"
import "core:reflect"

