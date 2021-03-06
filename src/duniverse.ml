(* Copyright (c) 2018 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Cmdliner
open Astring

let copts = ()

let setup_logs () =
  Printexc.record_backtrace true ;
  let setup_log style_renderer level =
    Fmt_tty.setup_std_outputs ?style_renderer () ;
    Logs.set_level level ;
    Logs.set_reporter (Logs_fmt.reporter ())
  in
  let global_option_section = "COMMON OPTIONS" in
  let open Term in
  const setup_log
  $ Fmt_cli.style_renderer ~docs:global_option_section ()
  $ Logs_cli.level ~docs:global_option_section ()

let copts_t =
  let _docs = Manpage.s_common_options in
  Term.(const copts)

let fpath_t = Arg.conv ~docv:"PATH" (Fpath.of_string, Fpath.pp)

let target_repo_t =
  let doc = "Path to Git repository to store vendored code in." in
  let open Arg in
  value
  & opt fpath_t (Fpath.v ".")
  & info ["r"; "--repo"] ~docv:"TARGET_REPO" ~doc

let branch_t =
  let doc =
    "Branch that represents the working tree of the source code.\n\
    \     If not supplied, the $(i,master) branch is used."
  in
  Arg.(value & opt string "master" & info ["b"] ~docv:"BRANCH" ~doc)

let exclude_t =
  let doc =
    "Packages to exclude from the output list. You can use this to remove the \
     root packages so they are not duplicated in the vendor directory.  \
     Repeat this flag multiple times for more than one exclusion."
  in
  Arg.(value & opt_all string [] & info ["exclude"; "x"] ~docv:"EXCLUDE" ~doc)

let remotes_t =
  let doc =
    "Extra opam remotes to add when resolving package names. Repeat this flag \
     multiple times for more than one remote."
  in
  Arg.(
    value & opt_all string [] & info ["opam-remote"] ~docv:"OPAM_REMOTE" ~doc)

let pins_t =
  let open Types.Opam in
  let doc =
    "Packages to pin for the latest opam metadata and source. You can \
     separate the package name and a url and a remote branch via commas to \
     specify a manual url (e.g. \
     $(i,mirage,git://github.com/avsm/mirage,fixme)).  If a url is not \
     specified then the $(i,--dev) pin is used.  If a branch is not specified \
     then the default remote branch is used. Repeat this flag multiple times \
     for more than one exclusion."
  in
  let fin s =
    match String.cuts ~sep:"," s with
    | [] -> failwith "unexpected pin error"
    | [pin] -> Ok {pin; url= None; tag= None}
    | [pin; url] -> Ok {pin; url= Some url; tag= None}
    | [pin; url; tag] -> Ok {pin; url= Some url; tag= Some tag}
    | _ -> failwith "pins must have maximum of 3 commas"
  in
  let fout ppf {pin; url; tag} =
    match (url, tag) with
    | None, _ -> Fmt.(pf ppf "%s" pin)
    | Some url, None -> Fmt.(pf ppf "%s,%s" pin url)
    | Some url, Some tag -> Fmt.(pf ppf "%s,%s,%s" pin url tag)
  in
  let t = Arg.conv ~docv:"PIN" (fin, fout) in
  Arg.(value & opt_all t [] & info ["pin"; "p"] ~docv:"PIN" ~doc)

let ocaml_switch_t =
  let doc =
    "Name of the OCaml compiler to use to resolve opam packages.  A local \
     switch is created in $(i,.duniverse) where pins and packages can be \
     tracked independently of your main opam switch.  This defaults to \
     $(i,ocaml-system), but you can use this flag to supply a more specific \
     version such as $(b,ocaml.4.06.1)."
  in
  let open Arg in
  value & opt string "ocaml-system"
  & info ["opam-switch"; "s"] ~docv:"OPAM_SWITCH" ~doc

let pkg_t =
  let open Arg in
  value & pos_all string []
  & info []
      ~doc:
        "opam packages to calculate duniverse for. If not supplied, any local \
         opam metadata files are used as the default package list."
      ~docv:"PACKAGES"

let opam_cmd =
  let doc = "analyse opam metadata to generate a standalone package list" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This command analyses the opam package metadata and generates an \
         $(i,opam.sxp) configuration file that contains the full dependency \
         list of packages and their compatibility status with Dune."
    ; `P
        "In the situation where a package has not been ported to Dune \
         upstream, we maintain a hardcoded list of forks that contain Dune \
         overlays at $(i,https://github.com/dune-universe).  This command \
         will detect these packages and supply the forked version if \
         available." ]
  in
  ( (let open Term in
    term_result
      ( const Opam_cmd.init_duniverse
      $ target_repo_t $ branch_t $ pkg_t $ exclude_t $ pins_t $ ocaml_switch_t
      $ remotes_t $ setup_logs () ))
  , Term.info "opam" ~doc ~exits ~man )

let dune_lock_cmd =
  let doc = "generate git tags suitable for vendoring from opam metadata" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This command takes the standalone opam package list calculated using \
         $(i,duniverse opam) and converts it into a set of git tags that can \
         be put into the $(b,ocaml_modules/) subdirectory and act as vendored \
         copies of the source code."
    ; `P
        "The opam packages are sorted by their Git remotes and deduplicated \
         so that only one clone is used per Git remote.  In the event of \
         multiple conflicting tags being found, the latest one is selected \
         and a warning printed.  The output is stored in \
         $(b,.duniverse/dune.sxp) and can be hand-edited if necessary to \
         tweak your vendoring setup."
    ; `P
        "This is currently a separate command as it will be extended in the \
         future to non-opam package managers as well." ]
  in
  ( (let open Term in
    term_result (const Dune_cmd.gen_dune_lock $ target_repo_t $ setup_logs ()))
  , Term.info "lock" ~doc ~exits ~man )

let dune_lockfile_t =
  let doc = "Input path of Dune lockfile" in
  let open Arg in
  value
  & opt fpath_t Config.duniverse_lockfile
  & info ["f"] ~docv:"DUNE_LOCKFILE" ~doc

let dune_fetch_cmd =
  let doc = "fetch the latest archives of the vendored libraries" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This command reads the Git metadata calculated with $(i,duniverse \
         lock) and fetches them from their respective Git remotes and stores \
         them in the $(b,ocaml_modules/) directory in the repository." ]
  in
  ( (let open Term in
    term_result
      ( const Dune_cmd.gen_dune_upstream_branches
      $ target_repo_t $ setup_logs () ))
  , Term.info "pull" ~doc ~exits ~man )

let vendor_lock_cmd =
  let doc = "calculate Dune metadata and git commit the results" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This initiaises a Git repository with the vendoring metadata for \
         Dune, and commits the results to the current branch.  It runs " ]
  in
  let man_xrefs = [`Cmd "git-pull"; `Cmd "git-merge"] in
  ( (let open Term in
    term_result
      ( const Git_cmd.update $ target_repo_t $ branch_t $ pkg_t $ exclude_t
      $ pins_t $ ocaml_switch_t $ remotes_t $ setup_logs () ))
  , Term.info "git-lock" ~doc ~exits ~man ~man_xrefs )

let vendor_pull_cmd =
  let doc = "pull vendored libraries and commit them to a branch" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This command wraps $(i,duniverse pull) with a workflow that stores \
         the vendored libraries in a git branch called \
         $(b,duniverse-of-<branch>).  By storing them in a separate branch, \
         you can then test that they work (e.g. with continuous integration) \
         and then integrate them either in your $(b,master) branch or in a \
         separate release branch."
    ; `P
        "Once this command is complete, you can merge the results with \
         $(i,duniverse git-merge)." ]
  in
  let man_xrefs = [`Cmd "git-lock"; `Cmd "git-merge"] in
  ( (let open Term in
    term_result (const Git_cmd.pull $ target_repo_t $ branch_t $ setup_logs ()))
  , Term.info "git-pull" ~doc ~exits ~man ~man_xrefs )

let vendor_merge_cmd =
  let doc = "merge vendored libraries into the mainline branch" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "The $(i,duniverse pull) command populates a vendor branch with the \
         external libraries. Once you have tested that it works, this command \
         will merge that vendor branch into your mainline git branch (usually \
         $(b,master))."
    ; `P
        "If at any point you wish to undo the vendoring, just delete the \
         contents of the $(b,ocaml_modules/) directory." ]
  in
  let man_xrefs = [`Cmd "git-lock"; `Cmd "git-pull"] in
  ( (let open Term in
    term_result (const Git_cmd.merge $ target_repo_t $ branch_t $ setup_logs ()))
  , Term.info "git-merge" ~doc ~exits ~man_xrefs ~man )

let status_cmd =
  let doc = "summarise the libraries tracked by the duniverse" in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P
        "This command looks at the various metadata files in the \
         $(b,.duniverse) directory and prints them out in a human-readable \
         format." ]
  in
  ( (let open Term in
    term_result
      (const Dune_cmd.status $ target_repo_t $ branch_t $ setup_logs ()))
  , Term.info "status" ~doc ~exits ~man )

let default_cmd =
  let doc = "the spice of build life" in
  let sdocs = Manpage.s_common_options in
  let man_xrefs =
    [ `Tool "dune"
    ; `Tool "opam"
    ; `Tool "git"
    ; `Cmd "git-lock"
    ; `Cmd "git-pull"
    ; `Cmd "git-merge" ]
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "The $(tname) tool provides a convenient interface to bridge the \
         $(b,opam) package manager with having a local copy of all the source \
         code required to build a project using the $(b,dune) build tool."
    ; `P
        "It works by analysing opam package metadata and calculating a set of \
         git tags that can be cloned into the local repository into an \
         $(i,ocaml_modules) subdirectory.  Once the external code has been \
         pulled into the repository, a single $(b,dune build) command is \
         sufficient to build the whole project in a standalone fashion, \
         without opam being required.  This is a particularly convenient way \
         of publishing CLI tools to users who do not need the full power of \
         opam."
    ; `P "The basic flow of the tool is provided by three git commands:"
    ; `I
        ( "\\$ $(tname) $(b,git-lock)"
        , "This converts the opam metadata into a set of git remotes, and \
           stores the data in $(i,.duniverse/dune.sxp)." )
    ; `I
        ( "\\$ $(tname) $(b,git-pull)"
        , "Pulls the vendored code into a $(i,duniverse-of-master) branch, \
           where you can test the project builds." )
    ; `I
        ( "\\$ $(tname) $(b,git-merge)"
        , "Merges the vendor branch into the mainline $(i,master) branch." )
    ; `P
        "You can access some of the low-level functionality directly via the \
         $(i,duniverse-opam), $(i,duniverse-lock) and $(i,duniverse-pull) \
         commands, but this should not be necessary usually."
    ; `S Manpage.s_examples
    ; `P
        "These commands will vendor the $(b,utop) and $(b,craml) commands \
         locally:"
    ; `P "\\$ $(b,duniverse git-lock --pin lwt utop craml)"
    ; `Noblank
    ; `P "\\$ $(b,duniverse git-pull)"
    ; `Noblank
    ; `P "\\$ $(b,duniverse git-merge)"
    ; `P
        "Also see $(i,https://github.com/avsm/platform) for an example of a \
         fully bootstrapping use of this tool." ]
  in
  ( Term.(ret (const (fun _ -> `Help (`Pager, None)) $ pure ()))
  , Term.info "duniverse" ~version:"%%VERSION%%" ~doc ~man_xrefs ~sdocs ~man )

let cmds =
  [ opam_cmd
  ; dune_lock_cmd
  ; dune_fetch_cmd
  ; status_cmd
  ; vendor_lock_cmd
  ; vendor_pull_cmd
  ; vendor_merge_cmd ]

let () = Term.(exit @@ eval_choice default_cmd cmds)
