package main

RECORDS_PATH :: "records.txt"

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

main :: proc() {
    context.logger = log.create_console_logger()
    f, err := os.open(RECORDS_PATH, {.Read, .Write, .Create})
    if err != nil {
	fmt.printf("cannot open %v: %v\n", RECORDS_PATH, err)
	return
    }
    defer os.close(f)

    start := time.now()
    end := time.now()

    content, err1 := read_all(f)
    if err1 != nil {
	fmt.printf("cannot read %v: %v\n", RECORDS_PATH, err1)
	return
    }

    for record in Record_deserialize(&content) {
	fmt.println(record)
    }
}

import "core:os"
import "core:fmt"
import "core:bytes"
import "core:time"
import "core:strconv"
import "core:log"

