open Core
open Async
open Coda_worker
open Coda_processes

(* A bare bones use case of the [Rpc_parallel] library. This demonstrates how to
   define a simple worker type that implements some functions. The master then spawns a
   worker of this type and calls a function to run on this worker *)

let main () =
  Coda_processes.init () ;
  let gossip_port = 8000 in
  let port = 3000 in
  let peers = [] in
  let%bind program_dir = Unix.getcwd () in
  Coda_process.spawn_local_exn ~peers ~port ~gossip_port ~program_dir
    ~f:(fun worker ->
      let%bind res = Coda_process.sum_exn worker 40 in
      let%bind peers = Coda_process.peers_exn worker in
      Print.printf "sum_worker: %d\n" res ;
      Print.printf !"peers: %{sexp: Host_and_port.t list}\n" peers;
      let%bind stream = Coda_process.stream_exn worker in
      let%bind () = Linear_pipe.iter stream ~f:(fun () -> Print.printf "got elem\n"; return ()) in
      let%bind () = after (Time.Span.of_sec 5.) in
      let%bind _ = Coda_process.disconnect worker in
      Deferred.unit
    )

let name = "coda-block-production-test"

let command =
  (* Make sure to always use [Command.async] *)
  Command.async_spec ~summary:"Simple use of Async Rpc_parallel V2"
    Command.Spec.(empty)
    main

(* This call to [Rpc_parallel.start_app] must be top level *)
(*let () = Rpc_parallel.start_app command *)
