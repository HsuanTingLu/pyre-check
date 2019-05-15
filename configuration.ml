(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Pyre


module Analysis = struct
  type t = {
    start_time: float;
    infer: bool;
    recursive_infer: bool;
    additional_checks: string list;
    configuration_file_hash: string option;
    parallel: bool;
    filter_directories: (Path.t list) option;
    ignore_all_errors: (Path.t list) option;
    number_of_workers: int;
    local_root: Path.t;
    sections: string list;
    debug: bool;
    project_root: Path.t;
    search_path: Path.SearchPath.t list;
    typeshed: Path.t option;
    verbose: bool;
    expected_version: string option;
    strict: bool;
    declare: bool;
    show_error_traces: bool;
    log_identifier: string;
    logger: string option;
    profiling_output: string option;
    excludes: Str.regexp list [@opaque];
    extensions: string list;
    store_type_check_resolution: bool;
  }
  [@@deriving show]


  let equal first second =
    first.infer = second.infer &&
    first.recursive_infer = second.recursive_infer &&
    first.additional_checks = second.additional_checks &&
    first.debug = second.debug &&
    first.expected_version = second.expected_version &&
    first.strict = second.strict &&
    first.declare = second.declare


  let create
      ?(start_time = Unix.time())
      ?(infer = false)
      ?(recursive_infer = false)
      ?(additional_checks = [])
      ?configuration_file_hash
      ?(parallel = true)
      ?filter_directories
      ?ignore_all_errors
      ?(number_of_workers = 4)
      ?(local_root = Path.current_working_directory ())
      ?(sections = [])
      ?(project_root = Path.create_absolute "/")
      ?(search_path = [])
      ?typeshed
      ?(verbose = false)
      ?expected_version
      ?(strict = false)
      ?(declare = false)
      ?(debug = false)
      ?(show_error_traces = false)
      ?(log_identifier = "")
      ?logger
      ?profiling_output
      ?(excludes = [])
      ?(extensions = [])
      ?(store_type_check_resolution = true)
      () =
    {
      start_time;
      infer;
      recursive_infer;
      additional_checks;
      configuration_file_hash;
      parallel;
      filter_directories;
      ignore_all_errors;
      number_of_workers;
      local_root;
      sections;
      debug;
      project_root;
      search_path;
      typeshed;
      verbose;
      expected_version;
      strict;
      declare;
      show_error_traces;
      log_identifier;
      logger;
      profiling_output;
      excludes = List.map excludes ~f:Str.regexp;
      extensions;
      store_type_check_resolution;
    }


  let global: t option ref =
    ref None


  let set_global configuration =
    global := Some configuration


  let get_global () =
    !global


  let localize ({ debug; strict; _ } as configuration) ~local_debug ~local_strict ~declare =
    {
      configuration with
      debug = debug || local_debug;
      strict = strict || local_strict;
      declare;
    }


  let pyre_root { local_root; _ } =
    Path.append local_root ~element:".pyre"


  let search_path { local_root; search_path; typeshed; _ } =
    (* Have an ordering of search_path > typeshed > local_root with the parser. search_path precedes
     * local_root due to the possibility of having a subdirectory of the root in the search path. *)
    let roots =
      match typeshed with
      | None ->
          [Path.SearchPath.Root local_root]
      | Some typeshed ->
          [
            Path.SearchPath.Root (Path.create_relative ~root:typeshed ~relative:"stdlib");
            Path.SearchPath.Root (Path.create_relative ~root:typeshed ~relative:"third_party");
            Path.SearchPath.Root local_root;
          ]
    in
    search_path @ roots
end


module Server = struct
  type load_parameters = {
    shared_memory_path: Path.t;
    changed_files_path: Path.t;
  }

  type load =
    | LoadFromFiles of load_parameters
    | LoadFromProject of { project_name: string; metadata: string option }

  type saved_state_action =
    | Save of string
    | Load of load

  type socket_path = {
    path: Path.t;
    link: Path.t;
  }

  type t = {
    (* Server-specific configuration options *)
    socket: socket_path;
    json_socket: socket_path;
    lock_path: Path.t;
    pid_path: Path.t;
    log_path: Path.t;
    daemonize: bool;
    saved_state_action: saved_state_action option;
    (* Analysis configuration *)
    configuration: Analysis.t;
  }

  (* Required to appease the compiler. *)
  let global: t option ref = ref None

  let set_global configuration =
    global := Some configuration

  let get_global () = !global
end


module StaticAnalysis = struct
  type t = {
    result_json_path: Path.t option;
    dump_call_graph: bool;
    (* Analysis configuration *)
    configuration: Analysis.t;
  }
end
