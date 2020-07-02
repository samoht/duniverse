open Stdune
open Sexplib.Conv

type unresolved = Git.Ref.t

type resolved = Git.Ref.resolved [@@deriving sexp]

module Deps = struct
  module Opam = struct
    type t = { name : string; version : string option [@default None] [@sexp_drop_default.sexp] }
    [@@deriving sexp]

    let equal t t' = String.equal t.name t'.name && Option.equal String.equal t.version t'.version

    let pp fmt = function
      | { name; version = None } -> Format.fprintf fmt "%s" name
      | { name; version = Some v } -> Format.fprintf fmt "%s.%s" name v

    let raw_pp fmt { name; version } =
      let open Pp_combinators.Ocaml in
      Format.fprintf fmt "@[<hov 2>{ name = %S;@ version = %a }@]" name (option string) version
  end

  module Source = struct
    module Package = struct
      type t = { opam : Opam.t; upstream : string; ref : Git.Ref.t }

      let equal t t' =
        Opam.equal t.opam t'.opam
        && String.equal t.upstream t'.upstream
        && Git.Ref.equal t.ref t'.ref

      let raw_pp fmt { opam; upstream; ref } =
        Format.fprintf fmt "@[<hov 2>{ opam = %a;@ upstream = %S;@ ref = %S }@]" Opam.raw_pp opam
          upstream ref
    end

    type 'ref t = {
      dir : string;
      upstream : string;
      ref : 'ref;
      provided_packages : Opam.t list; [@default []] [@sexp_drop_default.sexp]
    }
    [@@deriving sexp]

    let equal equal_ref t t' =
      let { dir; upstream; ref; provided_packages } = t in
      let { dir = dir'; upstream = upstream'; ref = ref'; provided_packages = provided_packages' } =
        t'
      in
      String.equal dir dir' && String.equal upstream upstream' && equal_ref ref ref'
      && List.equal Opam.equal provided_packages provided_packages'

    let raw_pp pp_ref fmt { dir; upstream; ref; provided_packages } =
      let open Pp_combinators.Ocaml in
      Format.fprintf fmt
        "@[<hov 2>{ dir = %S;@ upstream = %S;@ ref = %a;@ provided_packages = %a }@]" dir upstream
        pp_ref ref (list Opam.raw_pp) provided_packages

    let dir_name_from_package { Opam.name; version } =
      Printf.sprintf "%s.%s" name (match version with None -> "zdev" | Some x -> x)

    let from_package { Package.opam; upstream; ref } =
      let dir = dir_name_from_package opam in
      { dir; upstream; ref; provided_packages = [ opam ] }

    let aggregate t package =
      let package_name = package.Package.opam.name in
      let new_dir =
        match String.compare t.dir package_name with
        | Lt | Eq -> t.dir
        | Gt -> dir_name_from_package package.Package.opam
      in
      let new_ref =
        match Ordering.of_int (OpamVersionCompare.compare t.ref package.ref) with
        | Gt | Eq -> t.ref
        | Lt -> package.ref
      in
      {
        t with
        dir = new_dir;
        ref = new_ref;
        provided_packages = package.opam :: t.provided_packages;
      }

    let aggregate_packages l =
      let update map ({ Package.upstream; _ } as package) =
        String.Map.update map upstream ~f:(function
          | None -> Some (from_package package)
          | Some t -> Some (aggregate t package))
      in
      let aggregated_map = List.fold_left ~init:String.Map.empty ~f:update l in
      String.Map.values aggregated_map

    let resolve ~resolve_ref ({ upstream; ref; _ } as t) =
      let open Result.O in
      resolve_ref ~upstream ~ref >>= fun resolved_ref -> Ok { t with ref = resolved_ref }
  end

  module Classified = struct
    type t = Opam of Opam.t | Source of Source.Package.t

    let equal t t' =
      match (t, t') with
      | Opam opam, Opam opam' -> Opam.equal opam opam'
      | Source source, Source source' -> Source.Package.equal source source'
      | (Opam _ | Source _), _ -> false

    let raw_pp fmt t =
      match t with
      | Opam opam -> Format.fprintf fmt "@[<hov 2>Opam@ %a@]" Opam.raw_pp opam
      | Source source -> Format.fprintf fmt "@[<hov 2>Source@ %a@]" Source.Package.raw_pp source

    let from_opam_entry ~get_default_branch entry =
      let open Types.Opam in
      let open Result.O in
      match entry with
      | { dev_repo = `Virtual; _ } | { dev_repo = `Error _; _ } -> Ok None
      | { is_dune = false; package = { name; version }; _ } -> Ok (Some (Opam { name; version }))
      | { is_dune = true; dev_repo = `Git upstream; tag = Some ref; package = { name; version } } ->
          Ok (Some (Source { opam = { name; version }; upstream; ref }))
      | { is_dune = true; dev_repo = `Git upstream; tag = None; package = { name; version } } ->
          get_default_branch upstream >>= fun ref ->
          Ok (Some (Source { opam = { name; version }; upstream; ref }))
  end

  type 'ref t = { opamverse : Opam.t list; duniverse : 'ref Source.t list } [@@deriving sexp]

  let equal equal_ref t t' =
    List.equal Opam.equal t.opamverse t'.opamverse
    && List.equal (Source.equal equal_ref) t.duniverse t'.duniverse

  let raw_pp pp_ref fmt t =
    let open Pp_combinators.Ocaml in
    Format.fprintf fmt "@[<hov 2>{ opamverse = %a;@ duniverse = %a}@]" (list Opam.raw_pp)
      t.opamverse
      (list (Source.raw_pp pp_ref))
      t.duniverse

  let from_classified (l : Classified.t list) =
    let opamverse, source_deps =
      List.partition_map ~f:(function Opam o -> Left o | Source s -> Right s) l
    in
    let duniverse = Source.aggregate_packages source_deps in
    { opamverse; duniverse }

  let classify ~get_default_branch entries =
    let open Result.O in
    let results = List.map ~f:(Classified.from_opam_entry ~get_default_branch) entries in
    Result.List.all results >>= fun dep_options -> Ok (List.filter_opt dep_options)

  let from_opam_entries ~get_default_branch entries =
    let open Result.O in
    classify ~get_default_branch entries >>= fun classified -> Ok (from_classified classified)

  let count { opamverse; duniverse } = List.length opamverse + List.length duniverse

  let resolve ~resolve_ref t =
    let open Result.O in
    Parallel.map ~f:(Source.resolve ~resolve_ref) t.duniverse |> Result.List.all
    >>= fun duniverse -> Ok { t with duniverse }
end

module Depexts = struct
  type t = (string list * string) list [@@deriving sexp]
end

(** duniverse knows about which tools to use, and can calculate a set of allowable versions
    by inspecting the repo metadata *)
module Tools = struct
  type version = Eq of string | Latest | Min of string [@@deriving sexp]

  type t = {
    opam : version;
    ocamlformat : version;
    dune : version;
    odoc : version;
    mdx : version;
    lsp : version;
    merlin : version;
  }
  [@@deriving sexp]

  let tools =
    [
      ("base", [ "opam"; "odoc"; "mdx" ]);
      ("ocamlformat", [ "ocamlformat" ]);
      (* ("lsp", ["ocaml-lsp-server"]); TODO broken *)
      ("merlin", [ "merlin" ]);
    ]

  (** Calculate a version of this tool by looking at repo metadata *)
  let of_repo () =
    (* TODO expose CLI overrides *)
    let ocamlformat =
      match Bos.OS.File.read_lines (Fpath.v ".ocamlformat") with
      | Ok f -> (
          List.filter_map ~f:(Astring.String.cut ~sep:"=") f |> List.assoc_opt "version" |> function
          | Some v -> Eq v
          | None -> Latest )
      | Error (`Msg _) -> Latest
    in
    let dune = Latest in
    (* TODO check for minimum in dune-project *)
    let odoc = Latest in
    (* No real version constraints on odoc *)
    let opam = Latest in
    (* No real version constraints on opam *)
    let mdx = Latest in
    let lsp = Latest in
    let merlin = Latest in
    { ocamlformat; dune; odoc; opam; mdx; lsp; merlin }
end

module Config = struct
  type pull_mode = Submodules | Source [@@deriving sexp]

  type t = {
    version : string;
    root_packages : Types.Opam.package list;
    pins : Types.Opam.pin list; [@default []] [@sexp_drop_default.sexp]
    pull_mode : pull_mode; [@default Source]
    opam_repo : Uri_sexp.t;
        [@default Uri.of_string Config.duniverse_opam_repo] [@sexp_drop_default.sexp]
    ocaml_compilers : string list; [@default []]
    tools : Tools.t;
  }
  [@@deriving sexp] [@@sexp.allow_extra_fields]
end

type t = { config : Config.t; deps : resolved Deps.t; depexts : Depexts.t } [@@deriving sexp]

let of_opam : OpamFile.OPAM.t -> t = assert false

let to_opam : t -> OpamFile.OPAM.t = fun _ -> OpamFile.OPAM.empty

let load ~file = Persist.load_opam "duniverse" of_opam file

let sort ({ deps = { opamverse; duniverse }; _ } as t) =
  let sorted_opamverse =
    let open Deps.Opam in
    let compare opam opam' = String.compare opam.name opam'.name in
    List.sort ~compare opamverse
  in
  let sorted_duniverse =
    let open Deps.Source in
    let compare source source' = String.compare source.dir source'.dir in
    List.sort ~compare duniverse
  in
  { t with deps = { opamverse = sorted_opamverse; duniverse = sorted_duniverse } }

let save ~file t = Persist.save_opam "duniverse" to_opam file (sort t)
