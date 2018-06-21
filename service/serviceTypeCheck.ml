(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Analysis
open Pyre

module Scheduler = ServiceScheduler
module AstSharedMemory = ServiceAstSharedMemory
module Ignore = ServiceIgnore


type analysis_results = {
  errors: Error.t list;
  lookups: Lookup.t String.Map.t;
  number_files: int;
  coverage: Coverage.t;
}


let analyze_source
    ({ Configuration.verbose; sections; infer; _ } as configuration)
    environment
    ({ Source.path; metadata; _ } as source) =
  (* Re-initialize log for subprocesses. *)
  Log.initialize ~verbose ~sections;

  (* Override file-specific local debug configuraiton *)
  let { Source.Metadata.autogenerated; declare; debug; strict; version; number_of_lines; _ } =
    metadata
  in
  let configuration =
    Configuration.localize
      configuration
      ~local_debug:debug
      ~local_strict:strict
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
        lookup = None;
        coverage = Coverage.create ();
      }
    end
  else
    begin
      let timer = Timer.start () in
      Log.log ~section:`Check "Checking `%s`..." path;
      let errors =
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
        ~configuration
        ();
      errors
    end


let analyze_sources_parallel
    scheduler
    ({Configuration.source_root; project_root = directory; _ } as configuration)
    environment
    handles =
  let merge_lookups ~key:_ = function
    | `Both (lookup, _) -> Some lookup
    | `Left lookup -> Some lookup
    | `Right lookup -> Some lookup
  in
  let init = {
    errors = [];
    lookups = String.Map.empty;
    number_files = 0;
    coverage = Coverage.create ();
  }
  in
  let handles =
    handles
    |> List.filter ~f:(fun handle ->
        match AstSharedMemory.get_source handle with
        | Some { Source.path; _ } ->
            Path.create_relative ~root:source_root ~relative:path
            |> Path.directory_contains ~follow_symlinks:true ~directory
        | _ ->
            false)
  in
  handles
  |> Scheduler.map_reduce
    scheduler
    ~init:
      {
        errors = [];
        lookups = String.Map.empty;
        number_files = 0;
        coverage = Coverage.create ();
      }
    ~map:(fun _ handles ->
        Annotated.Class.AttributesCache.clear ();
        let result =
          List.fold ~init ~f:(
            fun {
              errors;
              lookups;
              number_files;
              coverage = total_coverage;
            }
              handle ->
              match AstSharedMemory.get_source handle with
              | Some source ->
                  let {
                    TypeCheck.Result.errors = new_errors;
                    lookup;
                    coverage;
                    _;
                  } =
                    analyze_source configuration environment source
                  in
                  {
                    errors = List.append new_errors errors;
                    lookups =
                      begin
                        match lookup with
                        | Some table ->
                            Map.set ~key:(File.Handle.show handle) ~data:table lookups
                        | None ->
                            lookups
                      end;
                    number_files = number_files + 1;
                    coverage = Coverage.sum total_coverage coverage;
                  }
              | None -> {
                  errors;
                  lookups;
                  number_files = number_files + 1;
                  coverage = total_coverage;
                })
            handles
        in
        Statistics.flush ();
        result)
    ~reduce:(fun left right ->
        let number_files = left.number_files + right.number_files in
        Log.log ~section:`Progress "Processed %d of %d sources" number_files (List.length handles);
        {
          errors = List.append left.errors right.errors;
          lookups = Map.merge ~f:merge_lookups left.lookups right.lookups;
          number_files;
          coverage = Coverage.sum left.coverage right.coverage;
        })
  |> (fun { errors; lookups; coverage; _ } ->
      (Ignore.postprocess handles errors, lookups, coverage))


let analyze_sources
    scheduler
    ({Configuration.source_root; project_root = directory; _ } as configuration)
    environment
    handles =
  Log.info "Checking...";

  Annotated.Class.AttributesCache.clear ();

  if Scheduler.is_parallel scheduler then
    analyze_sources_parallel scheduler configuration environment handles
  else
    let sources =
      let source handle =
        AstSharedMemory.get_source handle
        >>= fun ({ Source.path; _ } as source) ->
        let path = Path.create_relative ~root:source_root ~relative:path in
        if Path.directory_contains ~follow_symlinks:true ~directory path then
          Some source
        else
          None
      in
      List.filter_map ~f:source handles
    in
    let analyze_and_postprocess
        configuration
        (current_errors, lookups, total_coverage)
        ({ Source.path; _ } as source) =
      let { TypeCheck.Result.errors; lookup; coverage; _ } =
        analyze_source configuration environment source
      in
      let lookups =
        lookup
        >>| (fun lookup -> String.Map.set ~key:path ~data:lookup lookups)
        |> Option.value ~default:lookups
      in
      errors :: current_errors,
      lookups,
      Coverage.sum total_coverage coverage
    in
    let errors, lookups, coverage =
      List.fold
        ~init:([], String.Map.empty, Coverage.create ())
        ~f:(analyze_and_postprocess configuration)
        sources
    in
    let errors =
      List.concat errors
      |> Ignore.postprocess handles
    in
    errors, lookups, coverage
