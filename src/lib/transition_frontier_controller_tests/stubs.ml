open Async
open Core_kernel
open Protocols.Coda_pow
open Coda_base
open Signature_lib

module Make (Inputs : sig
  val max_length : int
end) =
struct
  (** [Stubs] is a set of modules used for testing different components of tfc  *)
  let max_length = Inputs.max_length

  module Time = Coda_base.Block_time

  module State_proof = struct
    include Coda_base.Proof

    let verify _ _ = return true
  end

  module Ledger_proof_statement = Transaction_snark.Statement
  module Pending_coinbase_stack_state =
    Transaction_snark.Pending_coinbase_stack_state

  module Ledger_proof = struct
    module Stable = struct
      module V1 = struct
        module T = struct
          type t =
            Ledger_proof_statement.Stable.V1.t * Sok_message.Digest.Stable.V1.t
          [@@deriving sexp, bin_io, yojson, version]
        end

        include T
      end

      module Latest = V1
    end

    (* TODO: remove bin_io, after fixing functors to accept this *)
    type t = Stable.V1.t [@@deriving sexp, bin_io, yojson]

    let underlying_proof (_ : t) = Proof.dummy

    let statement ((t, _) : t) : Ledger_proof_statement.t = t

    let statement_target (t : Ledger_proof_statement.t) = t.target

    let sok_digest (_, d) = d

    let dummy =
      ( Ledger_proof_statement.gen |> Quickcheck.random_value
      , Sok_message.Digest.default )

    let create ~statement ~sok_digest ~proof:_ = (statement, sok_digest)
  end

  module Ledger_proof_verifier = struct
    let verify _ _ ~message:_ = return true
  end

  module Staged_ledger_aux_hash = struct
    include Staged_ledger_hash.Aux_hash.Stable.V1

    let of_bytes = Staged_ledger_hash.Aux_hash.of_bytes

    let to_bytes = Staged_ledger_hash.Aux_hash.to_bytes
  end

  module Transaction_witness = Coda_base.Transaction_witness

  module Pending_coinbase = struct
    include Coda_base.Pending_coinbase.Stable.V1

    let ( hash_extra
        , oldest_stack
        , latest_stack
        , create
        , remove_coinbase_stack
        , update_coinbase_stack
        , merkle_root ) =
      Coda_base.Pending_coinbase.
        ( hash_extra
        , oldest_stack
        , latest_stack
        , create
        , remove_coinbase_stack
        , update_coinbase_stack
        , merkle_root )

    module Stack = Coda_base.Pending_coinbase.Stack
    module Coinbase_data = Coda_base.Pending_coinbase.Coinbase_data
  end

  module Pending_coinbase_hash = Coda_base.Pending_coinbase.Hash
  module Transaction_snark_work =
    Staged_ledger.Make_completed_work (Ledger_proof) (Ledger_proof_statement)

  module Staged_ledger_hash_binable = struct
    include Staged_ledger_hash

    let ( of_aux_ledger_and_coinbase_hash
        , aux_hash
        , ledger_hash
        , pending_coinbase_hash ) =
      Staged_ledger_hash.
        ( of_aux_ledger_and_coinbase_hash
        , aux_hash
        , ledger_hash
        , pending_coinbase_hash )
  end

  module Staged_ledger_diff = Staged_ledger.Make_diff (struct
    module Fee_transfer = Fee_transfer
    module Ledger_proof = Ledger_proof
    module Ledger_hash = Ledger_hash
    module Staged_ledger_hash = Staged_ledger_hash_binable
    module Staged_ledger_aux_hash = Staged_ledger_aux_hash
    module Compressed_public_key = Public_key.Compressed
    module User_command = User_command
    module Transaction_snark_work = Transaction_snark_work
    module Pending_coinbase = Pending_coinbase
    module Pending_coinbase_hash = Pending_coinbase_hash
  end)

  module External_transition =
    Coda_base.External_transition.Make
      (Staged_ledger_diff)
      (Consensus.Protocol_state)

  module Transaction = struct
    include Coda_base.Transaction.Stable.Latest

    let fee_excess, supply_increase =
      Coda_base.Transaction.(fee_excess, supply_increase)
  end

  module Staged_ledger = Staged_ledger.Make (struct
    module Compressed_public_key = Signature_lib.Public_key.Compressed
    module User_command = User_command
    module Fee_transfer = Coda_base.Fee_transfer
    module Coinbase = Coda_base.Coinbase
    module Transaction = Transaction
    module Ledger_hash = Coda_base.Ledger_hash
    module Frozen_ledger_hash = Coda_base.Frozen_ledger_hash
    module Ledger_proof_statement = Ledger_proof_statement
    module Proof = Proof
    module Sok_message = Coda_base.Sok_message
    module Ledger_proof = Ledger_proof
    module Ledger_proof_verifier = Ledger_proof_verifier
    module Staged_ledger_aux_hash = Staged_ledger_aux_hash
    module Staged_ledger_hash = Staged_ledger_hash_binable
    module Transaction_snark_work = Transaction_snark_work
    module Transaction_validator = Transaction_validator
    module Staged_ledger_diff = Staged_ledger_diff
    module Account = Coda_base.Account
    module Ledger = Coda_base.Ledger
    module Sparse_ledger = Coda_base.Sparse_ledger
    module Pending_coinbase = Pending_coinbase
    module Pending_coinbase_hash = Pending_coinbase_hash
    module Pending_coinbase_stack_state = Pending_coinbase_stack_state
    module Transaction_witness = Transaction_witness
  end)

  (* Generate valid payments for each blockchain state by having
     each user send a payment of one coin to another random
     user if they at least one coin*)
  let gen_payments accounts_with_secret_keys :
      User_command.With_valid_signature.t Sequence.t =
    let public_keys =
      List.map accounts_with_secret_keys ~f:(fun (_, account) ->
          Account.public_key account )
    in
    Sequence.filter_map (accounts_with_secret_keys |> Sequence.of_list)
      ~f:(fun (sender_sk, sender_account) ->
        let open Option.Let_syntax in
        let%bind sender_sk = sender_sk in
        let sender_keypair = Keypair.of_private_key_exn sender_sk in
        let%bind receiver_pk = List.random_element public_keys in
        let send_amount = Currency.Amount.of_int 1 in
        let sender_account_amount =
          sender_account.Account.Poly.balance |> Currency.Balance.to_amount
        in
        let%map _ = Currency.Amount.sub sender_account_amount send_amount in
        let payload : User_command.Payload.t =
          User_command.Payload.create ~fee:Fee.Unsigned.zero
            ~nonce:sender_account.Account.Poly.nonce
            ~memo:User_command_memo.dummy
            ~body:(Payment {receiver= receiver_pk; amount= send_amount})
        in
        User_command.sign sender_keypair payload )

  module Blockchain_state = External_transition.Protocol_state.Blockchain_state
  module Protocol_state = External_transition.Protocol_state
  module Diff_hash = Transition_frontier_persistence.Diff_hash

  module Diff_mutant_inputs = struct
    module Staged_ledger_aux_hash = Staged_ledger_aux_hash
    module Ledger_proof_statement = Ledger_proof_statement
    module Ledger_proof = Ledger_proof
    module Transaction_snark_work = Transaction_snark_work
    module Staged_ledger_diff = Staged_ledger_diff
    module External_transition = External_transition
    module Transaction_witness = Transaction_witness
    module Staged_ledger = Staged_ledger
    module Diff_hash = Diff_hash
    module Scan_state = Staged_ledger.Scan_state
    module Pending_coinbase_stack_state = Pending_coinbase_stack_state
    module Pending_coinbase_hash = Pending_coinbase_hash
    module Pending_coinbase = Pending_coinbase
  end

  module Diff_mutant =
    Transition_frontier_persistence.Diff_mutant.Make (Diff_mutant_inputs)

  module Transition_frontier_inputs = struct
    include Diff_mutant_inputs
    module Diff_mutant = Diff_mutant

    let max_length = Inputs.max_length
  end

  module Transition_frontier =
    Transition_frontier.Make (Transition_frontier_inputs)

  let gen_breadcrumb ~logger ~accounts_with_secret_keys :
      (   Transition_frontier.Breadcrumb.t Deferred.t
       -> Transition_frontier.Breadcrumb.t Deferred.t)
      Quickcheck.Generator.t =
    let open Quickcheck.Let_syntax in
    let gen_slot_advancement = Int.gen_incl 1 10 in
    let%map make_next_consensus_state =
      Consensus.For_tests.gen_consensus_state ~gen_slot_advancement
    in
    fun parent_breadcrumb_deferred ->
      let open Deferred.Let_syntax in
      let%bind parent_breadcrumb = parent_breadcrumb_deferred in
      let parent_staged_ledger =
        Transition_frontier.Breadcrumb.staged_ledger parent_breadcrumb
      in
      let transactions = gen_payments accounts_with_secret_keys in
      let _, largest_account =
        List.max_elt accounts_with_secret_keys
          ~compare:(fun (_, acc1) (_, acc2) -> Account.compare acc1 acc2)
        |> Option.value_exn
      in
      let largest_account_public_key = Account.public_key largest_account in
      let get_completed_work stmts =
        let {Keypair.public_key; _} = Keypair.create () in
        let prover = Public_key.compress public_key in
        Some
          Transaction_snark_work.Checked.
            { fee= Fee.Unsigned.of_int 1
            ; proofs=
                List.map stmts ~f:(fun stmt ->
                    (stmt, Sok_message.Digest.default) )
            ; prover }
      in
      let staged_ledger_diff =
        Staged_ledger.create_diff parent_staged_ledger ~logger
          ~self:largest_account_public_key ~transactions_by_fee:transactions
          ~get_completed_work
      in
      let%bind ( `Hash_after_applying next_staged_ledger_hash
               , `Ledger_proof ledger_proof_opt
               , `Staged_ledger _
               , `Pending_coinbase_data _ ) =
        Staged_ledger.apply_diff_unchecked parent_staged_ledger
          staged_ledger_diff
        |> Deferred.Or_error.ok_exn
      in
      let previous_transition_with_hash =
        Transition_frontier.Breadcrumb.transition_with_hash parent_breadcrumb
      in
      let previous_protocol_state =
        With_hash.data previous_transition_with_hash
        |> External_transition.Verified.protocol_state
      in
      let previous_ledger_hash =
        previous_protocol_state |> Protocol_state.blockchain_state
        |> Protocol_state.Blockchain_state.snarked_ledger_hash
      in
      let next_ledger_hash =
        Option.value_map ledger_proof_opt
          ~f:(fun (proof, _) ->
            Ledger_proof.statement proof |> Ledger_proof.statement_target )
          ~default:previous_ledger_hash
      in
      let next_blockchain_state =
        Blockchain_state.create_value
          ~timestamp:(Block_time.now Time.Controller.basic)
          ~snarked_ledger_hash:next_ledger_hash
          ~staged_ledger_hash:next_staged_ledger_hash
      in
      let previous_state_hash =
        Consensus.Protocol_state.hash previous_protocol_state
      in
      let consensus_state =
        make_next_consensus_state ~snarked_ledger_hash:previous_ledger_hash
          ~previous_protocol_state:
            With_hash.
              {data= previous_protocol_state; hash= previous_state_hash}
      in
      let protocol_state =
        Protocol_state.create_value ~previous_state_hash
          ~blockchain_state:next_blockchain_state ~consensus_state
      in
      let next_external_transition =
        External_transition.create ~protocol_state
          ~protocol_state_proof:Proof.dummy
          ~staged_ledger_diff:(Staged_ledger_diff.forget staged_ledger_diff)
      in
      (* We manually created a verified an external_transition *)
      let (`I_swear_this_is_safe_see_my_comment
            next_verified_external_transition) =
        External_transition.to_verified next_external_transition
      in
      let next_verified_external_transition_with_hash =
        With_hash.of_data next_verified_external_transition
          ~hash_data:
            (Fn.compose Consensus.Protocol_state.hash
               External_transition.Verified.protocol_state)
      in
      match%map
        Transition_frontier.Breadcrumb.build ~logger ~parent:parent_breadcrumb
          ~transition_with_hash:next_verified_external_transition_with_hash
      with
      | Ok new_breadcrumb ->
          Logger.info logger ~module_:__MODULE__ ~location:__LOC__
            ~metadata:
              [ ( "state_hash"
                , Transition_frontier.Breadcrumb.transition_with_hash
                    new_breadcrumb
                  |> With_hash.hash |> State_hash.to_yojson ) ]
            "Producing a breadcrumb with hash: $state_hash" ;
          new_breadcrumb
      | Error (`Fatal_error exn) ->
          raise exn
      | Error (`Validation_error e) ->
          failwithf !"Validation Error : %{sexp:Error.t}" e ()

  let create_snarked_ledger accounts_with_secret_keys =
    let accounts = List.map ~f:snd accounts_with_secret_keys in
    let proposer_account = List.hd_exn accounts in
    let root_snarked_ledger = Coda_base.Ledger.Db.create () in
    List.iter accounts ~f:(fun account ->
        let status, _ =
          Coda_base.Ledger.Db.get_or_create_account_exn root_snarked_ledger
            (Account.public_key account)
            account
        in
        assert (status = `Added) ) ;
    (root_snarked_ledger, proposer_account)

  let create_root_frontier ~logger accounts_with_secret_keys :
      Transition_frontier.t Deferred.t =
    let root_snarked_ledger, proposer_account =
      create_snarked_ledger accounts_with_secret_keys
    in
    let root_transaction_snark_scan_state =
      Staged_ledger.Scan_state.empty ()
    in
    let root_pending_coinbases =
      Pending_coinbase.create () |> Or_error.ok_exn
    in
    let genesis_protocol_state_with_hash =
      Consensus.For_tests.create_genesis_protocol_state
        (Ledger.of_database root_snarked_ledger)
    in
    let genesis_protocol_state =
      With_hash.data genesis_protocol_state_with_hash
    in
    let genesis_protocol_state_hash =
      With_hash.hash genesis_protocol_state_with_hash
    in
    let root_ledger_hash =
      genesis_protocol_state |> Consensus.Protocol_state.blockchain_state
      |> Blockchain_state.snarked_ledger_hash
      |> Frozen_ledger_hash.to_ledger_hash
    in
    Logger.info logger ~module_:__MODULE__ ~location:__LOC__
      ~metadata:[("root_ledger_hash", Ledger_hash.to_yojson root_ledger_hash)]
      "Snarked_ledger_hash is $root_ledger_hash" ;
    let dummy_staged_ledger_diff =
      let creator =
        Quickcheck.random_value Signature_lib.Public_key.Compressed.gen
      in
      { Staged_ledger_diff.diff=
          ( { completed_works= []
            ; user_commands= []
            ; coinbase= Staged_ledger_diff.At_most_two.Zero }
          , None )
      ; prev_hash= Coda_base.Staged_ledger_hash.genesis
      ; creator }
    in
    (* the genesis transition is assumed to be valid *)
    let (`I_swear_this_is_safe_see_my_comment root_transition) =
      External_transition.to_verified
        (External_transition.create ~protocol_state:genesis_protocol_state
           ~protocol_state_proof:Proof.dummy
           ~staged_ledger_diff:dummy_staged_ledger_diff)
    in
    let root_transition_with_data =
      {With_hash.data= root_transition; hash= genesis_protocol_state_hash}
    in
    let open Deferred.Let_syntax in
    let expected_merkle_root = Ledger.Db.merkle_root root_snarked_ledger in
    match%bind
      Staged_ledger.of_scan_state_pending_coinbases_and_snarked_ledger
        ~scan_state:root_transaction_snark_scan_state
        ~snarked_ledger:(Ledger.of_database root_snarked_ledger)
        ~expected_merkle_root ~pending_coinbases:root_pending_coinbases
    with
    | Ok root_staged_ledger ->
        let%map frontier =
          Transition_frontier.create ~logger
            ~root_transition:root_transition_with_data ~root_snarked_ledger
            ~root_staged_ledger
            ~consensus_local_state:
              (Consensus.Local_state.create
                 (Some (Account.public_key proposer_account)))
        in
        frontier
    | Error err ->
        Error.raise err

  let build_frontier_randomly ~gen_root_breadcrumb_builder frontier :
      unit Deferred.t =
    let root_breadcrumb = Transition_frontier.root frontier in
    (* HACK: This removes the overhead of having to deal with the quickcheck generator monad *)
    let deferred_breadcrumbs =
      gen_root_breadcrumb_builder root_breadcrumb |> Quickcheck.random_value
    in
    Deferred.List.iter deferred_breadcrumbs ~f:(fun deferred_breadcrumb ->
        let%bind breadcrumb = deferred_breadcrumb in
        Transition_frontier.add_breadcrumb_exn frontier breadcrumb )

  let gen_linear_breadcrumbs ~logger ~size ~accounts_with_secret_keys
      root_breadcrumb =
    Quickcheck.Generator.with_size ~size
    @@ Quickcheck_lib.gen_imperative_list
         (root_breadcrumb |> return |> Quickcheck.Generator.return)
         (gen_breadcrumb ~logger ~accounts_with_secret_keys)

  let add_linear_breadcrumbs ~logger ~size ~accounts_with_secret_keys ~frontier
      ~parent =
    let new_breadcrumbs =
      gen_linear_breadcrumbs ~logger ~size ~accounts_with_secret_keys parent
      |> Quickcheck.random_value
    in
    Deferred.List.iter new_breadcrumbs ~f:(fun breadcrumb ->
        let%bind breadcrumb = breadcrumb in
        Transition_frontier.add_breadcrumb_exn frontier breadcrumb )

  let add_child ~logger ~accounts_with_secret_keys ~frontier ~parent =
    let%bind new_node =
      ( gen_breadcrumb ~logger ~accounts_with_secret_keys
      |> Quickcheck.random_value )
      @@ Deferred.return parent
    in
    let%map () = Transition_frontier.add_breadcrumb_exn frontier new_node in
    new_node

  let gen_tree ~logger ~size ~accounts_with_secret_keys root_breadcrumb =
    Quickcheck.Generator.with_size ~size
    @@ Quickcheck_lib.gen_imperative_rose_tree
         (root_breadcrumb |> return |> Quickcheck.Generator.return)
         (gen_breadcrumb ~logger ~accounts_with_secret_keys)

  let gen_tree_list ~logger ~size ~accounts_with_secret_keys root_breadcrumb =
    Quickcheck.Generator.with_size ~size
    @@ Quickcheck_lib.gen_imperative_ktree
         (root_breadcrumb |> return |> Quickcheck.Generator.return)
         (gen_breadcrumb ~logger ~accounts_with_secret_keys)

  module Protocol_state_validator = Protocol_state_validator.Make (struct
    include Transition_frontier_inputs
    module Time = Time
    module State_proof = State_proof
  end)

  module Sync_handler = Sync_handler.Make (struct
    include Transition_frontier_inputs
    module Time = Time
    module Transition_frontier = Transition_frontier
    module Protocol_state_validator = Protocol_state_validator
  end)

  module Root_prover = Root_prover.Make (struct
    include Transition_frontier_inputs
    module Time = Time
    module Transition_frontier = Transition_frontier
    module Protocol_state_validator = Protocol_state_validator
  end)

  module Breadcrumb_visualizations = struct
    module Graph =
      Visualization.Make_ocamlgraph (Transition_frontier.Breadcrumb)

    let visualize ~filename ~f breadcrumbs =
      Out_channel.with_file filename ~f:(fun output_channel ->
          let graph = f breadcrumbs in
          Graph.output_graph output_channel graph )

    let graph_breadcrumb_list breadcrumbs =
      let initial_breadcrumb, tail_breadcrumbs =
        Non_empty_list.uncons breadcrumbs
      in
      let graph = Graph.add_vertex Graph.empty initial_breadcrumb in
      let graph, _ =
        List.fold tail_breadcrumbs ~init:(graph, initial_breadcrumb)
          ~f:(fun (graph, prev_breadcrumb) curr_breadcrumb ->
            let graph_with_node = Graph.add_vertex graph curr_breadcrumb in
            ( Graph.add_edge graph_with_node prev_breadcrumb curr_breadcrumb
            , curr_breadcrumb ) )
      in
      graph

    let visualize_list =
      visualize ~f:(fun breadcrumbs ->
          breadcrumbs |> Non_empty_list.of_list_opt |> Option.value_exn
          |> graph_breadcrumb_list )

    let graph_rose_tree tree =
      let rec go graph (Rose_tree.T (root, children)) =
        let graph' = Graph.add_vertex graph root in
        List.fold children ~init:graph'
          ~f:(fun graph (T (child, grand_children)) ->
            let graph_with_child = go graph (T (child, grand_children)) in
            Graph.add_edge graph_with_child root child )
      in
      go Graph.empty tree

    let visualize_rose_tree =
      visualize ~f:(fun breadcrumbs -> graph_rose_tree breadcrumbs)
  end

  module Network = struct
    type t =
      { logger: Logger.t
      ; ip_table: (Unix.Inet_addr.t, Transition_frontier.t) Hashtbl.t
      ; peers: Network_peer.Peer.t Hash_set.t }

    let create ~logger ~ip_table ~peers = {logger; ip_table; peers}

    let random_peers {peers; _} num_peers =
      let peer_list = Hash_set.to_list peers in
      List.take (List.permute peer_list) num_peers

    let catchup_transition {ip_table; _} peer state_hash =
      Deferred.Result.return
      @@
      let open Option.Let_syntax in
      let%bind frontier = Hashtbl.find ip_table peer.Network_peer.Peer.host in
      Sync_handler.transition_catchup ~frontier state_hash

    let mplus ma mb = if Option.is_some ma then ma else mb

    let get_staged_ledger_aux_and_pending_coinbases_at_hash {ip_table; _}
        inet_addr hash =
      Deferred.return
      @@ Result.of_option
           ~error:
             (Error.of_string
                "Peer could not find the staged_ledger_aux and \
                 pending_coinbase at hash")
           (let open Option.Let_syntax in
           let%bind frontier = Hashtbl.find ip_table inet_addr in
           Sync_handler.get_staged_ledger_aux_and_pending_coinbases_at_hash
             ~frontier hash)

    let get_ancestry {ip_table; logger; _} inet_addr consensus_state =
      Deferred.return
      @@ Result.of_option
           ~error:(Error.of_string "Peer could not produce an ancestor")
           (let open Option.Let_syntax in
           let%bind frontier = Hashtbl.find ip_table inet_addr in
           Root_prover.prove ~logger ~frontier consensus_state)

    let glue_sync_ledger {ip_table; logger; _} query_reader response_writer :
        unit =
      Pipe_lib.Linear_pipe.iter_unordered ~max_concurrency:8 query_reader
        ~f:(fun (ledger_hash, sync_ledger_query) ->
          Logger.info logger ~module_:__MODULE__ ~location:__LOC__
            ~metadata:
              [ ( "sync_ledger_query"
                , Syncable_ledger.Query.to_yojson Ledger.Addr.to_yojson
                    sync_ledger_query ) ]
            !"Processing ledger query: $sync_ledger_query" ;
          let trust_system = Trust_system.null () in
          let envelope_query = Envelope.Incoming.local sync_ledger_query in
          let%bind answer =
            Hashtbl.to_alist ip_table
            |> Deferred.List.find_map ~f:(fun (inet_addr, frontier) ->
                   let open Deferred.Option.Let_syntax in
                   let%map answer =
                     Sync_handler.answer_query ~frontier ledger_hash
                       envelope_query ~logger ~trust_system
                   in
                   Envelope.Incoming.wrap ~data:answer
                     ~sender:(Envelope.Sender.Remote inet_addr) )
          in
          match answer with
          | None ->
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                ~metadata:
                  [ ( "sync_ledger_query"
                    , Syncable_ledger.Query.to_yojson Ledger.Addr.to_yojson
                        sync_ledger_query ) ]
                "Could not find an answer for: $sync_ledger_query" ;
              Deferred.unit
          | Some answer ->
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                ~metadata:
                  [ ( "sync_ledger_query"
                    , Syncable_ledger.Query.to_yojson Ledger.Addr.to_yojson
                        sync_ledger_query ) ]
                "Found an answer for: $sync_ledger_query" ;
              Pipe_lib.Linear_pipe.write response_writer
                (ledger_hash, sync_ledger_query, answer) )
      |> don't_wait_for
  end

  module Network_builder = struct
    type peer_config =
      {num_breadcrumbs: int; accounts: (Private_key.t option * Account.t) list}

    type peer_with_frontier =
      {peer: Network_peer.Peer.t; frontier: Transition_frontier.t}

    type t =
      { me: Transition_frontier.t
      ; peers: peer_with_frontier List.t
      ; network: Network.t }

    module Constants = struct
      let init_ip = Int32.of_int_exn 1

      let init_discovery_port = 1337

      let time = Int64.of_int 1
    end

    let setup ~source_accounts ~logger configs =
      let%bind me = create_root_frontier ~logger source_accounts in
      let%map _, _, peers_with_frontiers =
        Deferred.List.fold
          ~init:(Constants.init_ip, Constants.init_discovery_port, []) configs
          ~f:(fun (ip, discovery_port, acc_peers)
             {num_breadcrumbs; accounts}
             ->
            let%bind frontier = create_root_frontier ~logger accounts in
            let%map () =
              build_frontier_randomly frontier
                ~gen_root_breadcrumb_builder:
                  (gen_linear_breadcrumbs ~logger ~size:num_breadcrumbs
                     ~accounts_with_secret_keys:accounts)
            in
            (* each peer has a distinct IP address, so we lookup frontiers by IP *)
            let peer =
              Network_peer.Peer.create
                (Unix.Inet_addr.inet4_addr_of_int32 ip)
                ~discovery_port ~communication_port:(discovery_port + 1)
            in
            let peer_with_frontier = {peer; frontier} in
            ( Int32.( + ) Int32.one ip
            , discovery_port + 2
            , peer_with_frontier :: acc_peers ) )
      in
      let network =
        let peer_hosts_and_frontiers =
          List.map peers_with_frontiers ~f:(fun {peer; frontier} ->
              (peer.host, frontier) )
        in
        let peers =
          List.map peers_with_frontiers ~f:(fun {peer; _} -> peer)
          |> Hash_set.of_list (module Network_peer.Peer)
        in
        Network.create ~logger
          ~ip_table:
            (Hashtbl.of_alist_exn
               (module Unix.Inet_addr)
               peer_hosts_and_frontiers)
          ~peers
      in
      {me; network; peers= List.rev peers_with_frontiers}

    let setup_me_and_a_peer ~source_accounts ~target_accounts ~logger
        ~num_breadcrumbs =
      let%map {me; network; peers} =
        setup ~source_accounts ~logger
          [{num_breadcrumbs; accounts= target_accounts}]
      in
      (me, List.hd_exn peers, network)

    let send_transition ~logger ~transition_writer ~peer:{peer; frontier}
        state_hash =
      let transition =
        Transition_frontier.(
          find_exn frontier state_hash
          |> Breadcrumb.transition_with_hash |> With_hash.data)
      in
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        ~metadata:
          [ ("peer", Network_peer.Peer.to_yojson peer)
          ; ("state_hash", State_hash.to_yojson state_hash) ]
        "Peer $peer sending $state_hash" ;
      let enveloped_transition =
        Envelope.Incoming.wrap ~data:transition
          ~sender:(Envelope.Sender.Remote peer.host)
      in
      Pipe_lib.Strict_pipe.Writer.write transition_writer
        (`Transition enveloped_transition, `Time_received Constants.time)

    let make_transition_pipe () =
      Pipe_lib.Strict_pipe.create ~name:(__MODULE__ ^ __LOC__)
        (Buffered (`Capacity 30, `Overflow Drop_head))
  end
end
