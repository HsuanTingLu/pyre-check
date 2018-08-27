(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Configuration
open Pyre


type result = {
  handles: File.Handle.t list;
  environment: (module Analysis.Environment.Handler);
  errors: Analysis.Error.t list;
}


(** Internal result type; not exposed. *)
type analyze_source_results = {
  errors: Analysis.Error.t list;
  number_files: int;
  coverage: Analysis.Coverage.t;
}


let analyze_source
    ({ Configuration.infer; _ } as configuration)
    environment
    ({ Source.path; metadata; _ } as source) =
  let open Analysis in
  (* Override file-specific local debug configuraiton *)
  let { Source.Metadata.autogenerated; local_mode; debug; version; number_of_lines; _ } =
    metadata
  in
  let local_strict, declare =
    match local_mode with
    | Source.Strict -> true, false
    | Source.Declare -> false, true
    | _ -> false, false
  in
  let configuration =
    Configuration.localize
      configuration
      ~local_debug:debug
      ~local_strict
      ~declare
  in

  if version < 3 || autogenerated then
    begin
      Log.log
        ~section:`Check
        "Skipping `%s` (%s)"
        path
        (if autogenerated then "auto-generated" else "Python 2.x");
      {
        TypeCheck.Result.errors = [];
        coverage = Coverage.create ();
      }
    end
  else
    begin
      let timer = Timer.start () in
      Log.log ~section:`Check "Checking `%s`..." path;
      let result =
        let check = if infer then Inference.infer else TypeCheck.check in
        check configuration environment source
      in
      Statistics.performance
        ~flush:false
        ~randomly_log_every:100
        ~section:`Check
        ~name:(Format.asprintf "SingleFileTypeCheck of %s" path)
        ~timer
        ~normals:["path", path; "request kind", "SingleFileTypeCheck"]
        ~integers:["number of lines", number_of_lines]
        ();
      result
    end


let analyze_sources_parallel scheduler configuration environment handles =
  let open Analysis in
  let timer = Timer.start () in
  let init = {
    errors = [];
    number_files = 0;
    coverage = Coverage.create ();
  }
  in
  let { errors; coverage; _ } =
    Scheduler.map_reduce
      scheduler
      ~configuration
      handles
      ~bucket_size:75
      ~init:
        {
          errors = [];
          number_files = 0;
          coverage = Coverage.create ();
        }
      ~map:(fun _ handles ->
          Annotated.Class.AttributesCache.clear ();
          let result =
            List.fold ~init ~f:(
              fun {
                errors;
                number_files;
                coverage = total_coverage;
              }
                handle ->
                match Ast.SharedMemory.get_source handle with
                | Some source ->
                    let {
                      TypeCheck.Result.errors = new_errors;
                      coverage;
                      _;
                    } =
                      analyze_source configuration environment source
                    in
                    {
                      errors = List.append new_errors errors;
                      number_files = number_files + 1;
                      coverage = Coverage.sum total_coverage coverage;
                    }
                | None -> {
                    errors;
                    number_files = number_files + 1;
                    coverage = total_coverage;
                  })
              handles
          in
          Statistics.flush ();
          result)
      ~reduce:(fun left right ->
          let number_files = left.number_files + right.number_files in
          Log.log
            ~section:`Progress
            "Processed %d of %d sources"
            number_files
            (List.length handles);
          {
            errors = List.append left.errors right.errors;
            number_files;
            coverage = Coverage.sum left.coverage right.coverage;
          })
  in
  Statistics.performance ~name:"analyzed sources" ~timer ();
  let timer = Timer.start () in
  let errors = Postprocess.ignore ~configuration scheduler handles errors in
  Statistics.performance ~name:"postprocessed" ~timer ();
  errors, coverage


let analyze_sources
    scheduler
    ({ Configuration.local_root; project_root; filter_directories; _ } as configuration)
    environment
    handles =
  let open Analysis in

  Annotated.Class.AttributesCache.clear ();
  let timer = Timer.start () in
  let handles =
    let filter_by_directories path =
      match filter_directories with
      | None ->
          true
      | Some filter_directories ->
          List.exists
            filter_directories
            ~f:(fun directory -> Path.directory_contains ~follow_symlinks:true ~directory path)
    in
    let filter_by_root handle =
      match Ast.SharedMemory.get_source handle with
      | Some { Source.path; _ } ->
          let relative = Path.create_relative ~root:local_root ~relative:path in
          Path.directory_contains relative ~follow_symlinks:true ~directory:project_root &&
          filter_by_directories relative
      | _ ->
          false
    in
    Scheduler.map_reduce
      scheduler
      ~configuration
      ~map:(fun _ handles -> List.filter handles ~f:filter_by_root)
      ~reduce:(fun handles new_handles -> List.rev_append new_handles handles)
      ~init:[]
      handles
    |> List.sort ~compare:File.Handle.compare
  in
  Statistics.performance ~name:"filtered directories" ~timer ();
  Log.info "Checking %d sources..." (List.length handles);
  analyze_sources_parallel scheduler configuration environment handles


let check
    {
      start_time = _;
      verbose;
      expected_version = _;
      sections;
      debug;
      infer;
      recursive_infer;
      strict;
      declare;
      show_error_traces;
      log_identifier;
      parallel;
      filter_directories;
      number_of_workers;
      project_root;
      search_path;
      typeshed;
      local_root;
      logger;
    }
    original_scheduler
    () =
  let configuration =
    Configuration.create
      ~verbose
      ~sections
      ~local_root
      ~debug
      ~strict
      ~declare
      ~show_error_traces
      ~log_identifier
      ~project_root
      ~parallel
      ?filter_directories
      ~number_of_workers
      ~search_path
      ?typeshed
      ~infer
      ~recursive_infer
      ?logger
      ()
  in
  Scheduler.initialize_process ~configuration;

  let check_directory_exists directory =
    if not (Path.is_directory directory) then
      raise (Invalid_argument (Format.asprintf "`%a` is not a directory" Path.pp directory));
  in
  check_directory_exists local_root;
  check_directory_exists project_root;
  List.iter ~f:check_directory_exists search_path;
  Option.iter typeshed ~f:check_directory_exists;

  let bucket_multiplier =
    try Int.of_string (Sys.getenv "BUCKET_MULTIPLIER" |> (fun value -> Option.value_exn value))
    with _ -> 10
  in
  let scheduler =
    match original_scheduler with
    | None -> Scheduler.create ~configuration ~bucket_multiplier ()
    | Some scheduler -> scheduler
  in
  (* Parsing. *)
  let { Parser.stubs; sources } = Parser.parse_all scheduler ~configuration in
  (* Coverage. *)
  let () =
    let number_of_files = List.length sources in
    let { Coverage.strict_coverage; declare_coverage; default_coverage; source_files } =
      Coverage.coverage ~sources ~number_of_files
    in
    let path_to_files =
      Path.get_relative_to_root ~root:project_root ~path:local_root
      |> Option.value ~default:(Path.absolute local_root)
    in

    Statistics.coverage
      ~path:path_to_files
      ~coverage:[
        "strict_coverage", strict_coverage;
        "declare_coverage", declare_coverage;
        "default_coverage", default_coverage;
        "source_files", source_files;
      ]
      ()
  in

  (* Build environment. *)
  Postprocess.register_ignores ~configuration scheduler sources;
  let environment =
    Environment.handler ~configuration ~stubs ~sources
  in
  let errors, { Analysis.Coverage.full; partial; untyped; ignore; crashes } =
    analyze_sources scheduler configuration environment sources
  in
  (* Log coverage results *)
  let path_to_files =
    Path.get_relative_to_root ~root:project_root ~path:local_root
    |> Option.value ~default:(Path.absolute local_root)
  in
  Statistics.coverage
    ~path:path_to_files
    ~coverage:[
      "full_type_coverage", full;
      "partial_type_coverage", partial;
      "no_type_coverage", untyped;
      "ignore_coverage", ignore;
      "total_errors", List.length errors;
      "crashes", crashes;
    ]
    ();

  (* Only destroy the scheduler if the check command created it. *)
  begin
    match original_scheduler with
    | None -> Scheduler.destroy scheduler
    | Some _ -> ()
  end;
  { handles = stubs @ sources; environment; errors }
