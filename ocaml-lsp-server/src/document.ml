open! Import

module Kind = struct
  type t =
    | Intf
    | Impl

  let of_fname p =
    match Filename.extension p with
    | ".ml"
    | ".eliom"
    | ".re" ->
      Impl
    | ".mli"
    | ".eliomi"
    | ".rei" ->
      Intf
    | ext ->
      Jsonrpc.Response.Error.raise
        (Jsonrpc.Response.Error.make ~code:InvalidRequest
           ~message:(Printf.sprintf "unsupported file extension")
           ~data:(`Assoc [ ("extension", `String ext) ])
           ())
end

module Syntax = struct
  type t =
    | Ocaml
    | Reason
    | Ocamllex
    | Menhir

  let human_name = function
    | Ocaml -> "OCaml"
    | Reason -> "Reason"
    | Ocamllex -> "OCamllex"
    | Menhir -> "Menhir/ocamlyacc"

  let all =
    [ ("ocaml.interface", Ocaml)
    ; ("ocaml", Ocaml)
    ; ("reason", Reason)
    ; ("ocaml.ocamllex", Ocamllex)
    ; ("ocaml.menhir", Menhir)
    ]

  let of_fname s =
    match Filename.extension s with
    | ".eliomi"
    | ".eliom"
    | ".mli"
    | ".ml" ->
      Ocaml
    | ".rei"
    | ".re" ->
      Reason
    | ".mll" -> Ocamllex
    | ".mly" -> Menhir
    | ext ->
      Jsonrpc.Response.Error.raise
        (Jsonrpc.Response.Error.make ~code:InvalidRequest
           ~message:(Printf.sprintf "unsupported file extension")
           ~data:(`Assoc [ ("extension", `String ext) ])
           ())

  let of_language_id language_id =
    match List.assoc all language_id with
    | Some id -> id
    | None ->
      Jsonrpc.Response.Error.raise
        (Jsonrpc.Response.Error.make ~code:InvalidRequest
           ~message:(Printf.sprintf "invalid language ID")
           ~data:(`Assoc [ ("language_id", `String language_id) ])
           ())

  let to_language_id x =
    List.find_map all ~f:(fun (k, v) -> Option.some_if (v = x) k)
    |> Option.value_exn

  let markdown_name = function
    | Ocaml -> "ocaml"
    | Reason -> "reason"
    | s -> to_language_id s
end

type t =
  { tdoc : Text_document.t
  ; pipeline : Mpipeline.t Lazy_fiber.t
  ; merlin : Scheduler.thread
  ; timer : Scheduler.timer
  }

let uri doc = Text_document.documentUri doc.tdoc

let kind t = Kind.of_fname (Uri.to_path (uri t))

let syntax t = Syntax.of_language_id (Text_document.languageId t.tdoc)

let timer t = t.timer

let source t = Msource.make (Text_document.text t.tdoc)

let await task =
  let open Fiber.O in
  let* () = Server.on_cancel (fun () -> Scheduler.cancel_task task) in
  let+ res = Scheduler.await task in
  match res with
  | Error `Cancelled ->
    let e =
      Jsonrpc.Response.Error.make ~code:RequestCancelled ~message:"cancelled" ()
    in
    raise (Jsonrpc.Response.Error.E e)
  | Error (`Exn e) -> Error e
  | Ok s -> Ok s

let with_pipeline (t : t) f =
  let open Fiber.O in
  let* pipeline = Lazy_fiber.force t.pipeline in
  Scheduler.async_exn t.merlin (fun () ->
      Mpipeline.with_pipeline pipeline (fun () -> f pipeline))
  |> await

let with_pipeline_exn doc f =
  let open Fiber.O in
  let+ res = with_pipeline doc f in
  match res with
  | Ok s -> s
  | Error exn -> Exn_with_backtrace.reraise exn

let version doc = Text_document.version doc.tdoc

let make_config uri =
  let path = Uri.to_path uri in
  let mconfig = Mconfig.initial in
  let path = Merlin_utils.Misc.canonicalize_filename path in
  let filename = Filename.basename path in
  let directory = Filename.dirname path in
  let mconfig =
    { mconfig with
      ocaml = { mconfig.ocaml with real_paths = false }
    ; query = { mconfig.query with filename; directory }
    }
  in
  Mconfig.get_external_config path mconfig

let make_pipeline thread tdoc =
  Lazy_fiber.create (fun () ->
      let async_make_pipeline =
        Scheduler.async_exn thread (fun () ->
            let config =
              let uri = Text_document.documentUri tdoc in
              make_config uri
            in
            Text_document.text tdoc |> Msource.make |> Mpipeline.make config)
      in
      let open Fiber.O in
      let+ res = await async_make_pipeline in
      match res with
      | Ok s -> s
      | Error e -> Exn_with_backtrace.reraise e)

let make timer merlin_thread (tdoc : DidOpenTextDocumentParams.t) =
  let tdoc = Text_document.make tdoc in
  let pipeline = make_pipeline merlin_thread tdoc in
  { tdoc; pipeline; merlin = merlin_thread; timer }

let update_text ?version ({ merlin; tdoc; _ } as t) changes =
  match
    List.fold_left changes ~init:tdoc ~f:(fun acc change ->
        Text_document.apply_content_change ?version acc change)
  with
  | exception Text_document.Invalid_utf8 ->
    Log.log ~section:"warning" (fun () ->
        Log.msg "dropping update due to invalid utf8"
          [ ( "changes"
            , Json.yojson_of_list TextDocumentContentChangeEvent.yojson_of_t
                changes )
          ]);
    t
  | tdoc ->
    let pipeline = make_pipeline merlin tdoc in
    { t with tdoc; pipeline }

let dispatch (doc : t) command =
  with_pipeline doc (fun pipeline -> Query_commands.dispatch pipeline command)

let dispatch_exn (doc : t) command =
  with_pipeline_exn doc (fun pipeline ->
      Query_commands.dispatch pipeline command)

let close t = Scheduler.cancel_timer t.timer

let get_impl_intf_counterparts uri =
  let fpath = Uri.to_path uri in
  let fname = Filename.basename fpath in
  let ml, mli, eliom, eliomi, re, rei, mll, mly =
    ("ml", "mli", "eliom", "eliomi", "re", "rei", "mll", "mly")
  in
  let exts_to_switch_to =
    match Syntax.of_fname fname with
    | Ocaml -> (
      match Kind.of_fname fname with
      | Intf -> [ ml; mly; mll; eliom; re ]
      | Impl -> [ mli; mly; mll; eliomi; rei ])
    | Reason -> (
      match Kind.of_fname fname with
      | Intf -> [ re; ml ]
      | Impl -> [ rei; mli ])
    | Ocamllex -> [ mli; rei ]
    | Menhir -> [ mli; rei ]
  in
  let fpath_w_ext ext = Filename.remove_extension fpath ^ "." ^ ext in
  let find_switch exts =
    List.filter_map exts ~f:(fun ext ->
        let file_to_switch_to = fpath_w_ext ext in
        Option.some_if (Sys.file_exists file_to_switch_to) file_to_switch_to)
  in
  let files_to_switch_to =
    match find_switch exts_to_switch_to with
    | [] ->
      let switch_to_ext = List.hd exts_to_switch_to in
      let switch_to_fpath = fpath_w_ext switch_to_ext in
      [ switch_to_fpath ]
    | to_switch_to -> to_switch_to
  in
  List.map ~f:Uri.of_path files_to_switch_to
