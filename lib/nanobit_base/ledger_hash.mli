open Core
open Import
open Snark_params
open Snarky
open Tick

include Data_hash.Full_size

type path = Pedersen.Digest.t list

type _ Request.t +=
  | Get_path: Account.Index.t -> path Request.t
  | Get_element: Account.Index.t -> (Account.t * path) Request.t
  | Set: Account.Index.t * Account.t -> unit Request.t
  | Find_index: Public_key.Compressed.t -> Account.Index.t Request.t

val modify_account :
     var
  -> Public_key.Compressed.var
  -> f:(Account.var -> (Account.var, 's) Checked.t)
  -> (var, 's) Checked.t

val create_account : var -> Public_key.Compressed.var -> (var, _) Checked.t