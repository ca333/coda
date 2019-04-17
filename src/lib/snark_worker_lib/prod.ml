[%%import
"../../config.mlh"]

open Core
open Async
open Signature_lib

module Cache = struct
  module T = Hash_heap.Make (Transaction_snark.Statement)

  type t = (Time.t * Transaction_snark.t) T.t

  let max_size = 100

  let create () : t = T.create (fun (t1, _) (t2, _) -> Time.compare t1 t2)

  let add t ~statement ~proof =
    T.push_exn t ~key:statement ~data:(Time.now (), proof) ;
    if Int.( > ) (T.length t) max_size then ignore (T.pop_exn t)

  let find (t : t) statement = Option.map ~f:snd (T.find t statement)
end

module Inputs = struct
  module Worker_state = struct
    module type S = Transaction_snark.S

    type t = {m: (module S); cache: Cache.t}

    let create () =
      let%map proving = Snark_keys.transaction_proving ()
      and verification = Snark_keys.transaction_verification () in
      { m=
          ( module Transaction_snark.Make (struct
            let keys = {Transaction_snark.Keys.proving; verification}
          end)
          : S )
      ; cache= Cache.create () }

    let worker_wait_time = 5.
  end

  module Proof = Transaction_snark.Stable.V1
  module Statement = Transaction_snark.Statement.Stable.V1

  module Public_key = struct
    include Public_key.Compressed

    let arg_type = Cli_lib.Arg_type.public_key_compressed
  end

  module Transaction = Coda_base.Transaction.Stable.V1
  module Sparse_ledger = Coda_base.Sparse_ledger.Stable.V1
  module Pending_coinbase = Coda_base.Pending_coinbase.Stable.V1
  module Transaction_witness = Coda_base.Transaction_witness.Stable.V1

  type single_spec =
    ( Statement.t
    , Transaction.t
    , Transaction_witness.t
    , Transaction_snark.t )
    Snark_work_lib.Work.Single.Spec.t
  [@@deriving sexp]

  (* TODO: Use public_key once SoK is implemented *)
  let perform_single ({m= (module M); cache} : Worker_state.t) ~message =
    let open Snark_work_lib in
    let sok_digest = Coda_base.Sok_message.digest message in
    fun (single : single_spec) ->
      let statement = Work.Single.Spec.statement single in
      let process k =
        let start = Time.now () in
        match k () with
        | Error e ->
            Logger.error (Logger.create ()) ~module_:__MODULE__
              ~location:__LOC__
              ~metadata:
                [ ( "spec"
                  , `String (Sexp.to_string (sexp_of_single_spec single)) ) ]
              "Worker failed: %s" (Error.to_string_hum e) ;
            Error.raise e
        | Ok res ->
            Cache.add cache ~statement ~proof:res ;
            let total = Time.abs_diff (Time.now ()) start in
            Ok (res, total)
      in
      match Cache.find cache statement with
      | Some proof -> Or_error.return (proof, Time.Span.zero)
      | None -> (
        match single with
        | Work.Single.Spec.Transition (input, t, (w : Transaction_witness.t))
          ->
            process (fun () ->
                Or_error.try_with (fun () ->
                    M.of_transaction ~sok_digest ~source:input.Statement.source
                      ~target:input.target t
                      ~pending_coinbase_stack_state:
                        input.Statement.pending_coinbase_stack_state
                      (unstage (Coda_base.Sparse_ledger.handler w.ledger)) ) )
        | Merge (_, proof1, proof2) ->
            process (fun () -> M.merge ~sok_digest proof1 proof2) )

  [%%if
  curve_size = 298 && proof_level = "full"]

  let%test_unit "perform troublesome case" =
    Snarky.Snark.set_eval_constraints true ;
    let w =
      Async.Thread_safe.block_on_async_exn (fun () -> Worker_state.create ())
    in
    let input : single_spec =
      let c x = Fn.flip Sexp.of_string_conv_exn x in
      let open Coda_base in
      Snark_work_lib.Work.Single.Spec.Transition
        ( { source=
              c Frozen_ledger_hash.t_of_sexp
                "352647765919525510261397557724863761290546022214443504167797522916896333170772236312565349"
          ; target=
              c Frozen_ledger_hash.t_of_sexp
                "344946250516733982428441382768814731522776835347050691041815100300731840962124384388240454"
          ; supply_increase= Currency.Amount.of_int 10
          ; pending_coinbase_stack_state=
              { Transaction_snark.Pending_coinbase_stack_state.source=
                  c Coda_base.Pending_coinbase.Stack.t_of_sexp
                    "213165499557810234850189427376099483927952985934705223919227671465366729991150166525020427"
              ; target=
                  c Coda_base.Pending_coinbase.Stack.t_of_sexp
                    "459688999113022671209900593448315661604463577685272937028109826245853777972365589190969573"
              }
          ; fee_excess= Currency.Fee.Signed.zero
          ; proof_type= `Base }
        , Coinbase
            ( Coinbase.create
                ~amount:(Currency.Amount.of_int 10)
                ~proposer:
                  { x=
                      Snark_params.Tick.Field.of_string
                        "39876046544032071884326965137489542106804584544160987424424979200505499184903744868114140"
                  ; is_odd= true }
                ~fee_transfer:
                  (Some
                     ( { x=
                           Snark_params.Tick.Field.of_string
                             "221715137372156378645114069225806158618712943627692160064142985953895666487801880947288786"
                       ; is_odd= true }
                     , Currency.Fee.of_int 1 ))
            |> Or_error.ok_exn )
        , { ledger=
              Sexp.of_string_conv_exn
                "((indexes((((x \
                 221715137372156378645114069225806158618712943627692160064142985953895666487801880947288786)(is_odd \
                 true))18)(((x \
                 39876046544032071884326965137489542106804584544160987424424979200505499184903744868114140)(is_odd \
                 true))3)))(depth 30)(tree(Node \
                 352647765919525510261397557724863761290546022214443504167797522916896333170772236312565349(Node \
                 68597638566504008158898260632554037881039971398018984892420815749796071088219718585264591(Node \
                 97819527843204148778041976941904127836976909733128476819338150281579247228456865697493147(Node \
                 253987063990599299063541444706424087426580174778790239661404970594851500239045068707206326(Node \
                 306521898002312225633568267618666103926549959898398891851636427354411027935233526020547970(Node \
                 34057661902558934643704473443835054317807630651445060091159497017997272140020959122788023(Node \
                 339274216191960207728072164168803237937750466349155220836620438586376365746192969993347946(Node \
                 239855297026692385800074335214253647801294140865209049348814465453521943514888882654589853(Node \
                 121297739193057814092265302506396230194038063349019844380031860202853852516217299539877550(Node \
                 335323560160220003416498167079326165232075794051006380944262512822622842761009547762390181(Node \
                 283749538572959244806418029402050906378893414736419369387585786374345706927067338454265012(Node \
                 203234773030125746917376663613180152533997178967969850393138784542982206838359225133639251(Node \
                 336060616549246674217288100309655457107445888506102259324087940179485288734377998843463163(Node \
                 411424488771587576088642454894300812093512357752471649818462901610427174381056383961674255(Node \
                 464769952494080659581747572127746918955829034367124488853451157138292007300379716804836484(Node \
                 101420826714287681826536936478052782515858492904946192023104939401188366423251102283781289(Node \
                 375962059669108811424254836768322974336936214748203020388604453686157666237855805792704194(Node \
                 344896504320587726605913404072924112216079731890795594088036336634073000794386781864111466(Node \
                 134095797952298541995595524158553122691033608545406302293287874503492013690733386809297202(Node \
                 401142435492047134742884623020151788684830624804082279596025372590034745344582417754791229(Node \
                 71432342145581011173589660033419290760662063913801011933677916810933618046233711072482459(Node \
                 445252233832348962256758284682701316076695573349129402132668177011611441917793355757795553(Node \
                 255359834453838131461165908756629661095173248250029909553862455163698310672110591848832143(Node \
                 40794739730166341664957113112817447351012441487386649144378659639073073339970754790494524(Node \
                 176930547371017150778734901032533155183799667818800952800055341151791785031707714214304672(Node \
                 44304346483913663742442227288215659621856252405598792492106169220883738292516976260257306(Node \
                 280753438312806669470042926543540679557637789074618857012807073491520330343347514338823930(Node \
                 311775281891458569367367462979896092385770494465566962686156802651250548534030491229959625(Node \
                 249516479472664283612846560250056168765077353120165312744608482624781083698474403993178040(Hash \
                 454018384694953885751562813335453479254002433449739803783034272171286551098593798867710640)(Node \
                 416128942435537992359016988217754621495629670270619094859666919246924235911002010145286396(Hash \
                 164192364349193561618361722625548821719269845884200289863892392782808362813457759166928134)(Account((public_key((x \
                 39876046544032071884326965137489542106804584544160987424424979200505499184903744868114140)(is_odd \
                 true)))(balance 5000010)(nonce 0)(receipt_chain_hash \
                 278054398225185431268877077628619312925825005459146432606742566250670762499780565849108791)(delegate((x \
                 39876046544032071884326965137489542106804584544160987424424979200505499184903744868114140)(is_odd \
                 true)))(participated false)))))(Hash \
                 361755214976066318223800280145356234474949008140340721600465623888221932150431469736471905))(Hash \
                 258782510514112030621464014954751345274814570291785307189870923735379225180634205709047399))(Node \
                 441620842936966576500150392646311129567543076782752862511115511890853011461237808885796026(Node \
                 435441019591499956173785916707379749357940633059598421641878308795344445637619755127493104(Node \
                 375912838243170450657889786006657126085366914118050597500477529940708072074115626221412791(Hash \
                 8928360674495737174549695976820225716832659557438767035775653839997776981608751194058761)(Node \
                 366318747786759139091119051568444784729085632221714371185624497056105533065528996971897647(Account((public_key((x \
                 0)(is_odd false)))(balance 0)(nonce 0)(receipt_chain_hash \
                 278054398225185431268877077628619312925825005459146432606742566250670762499780565849108791)(delegate((x \
                 0)(is_odd false)))(participated false)))(Hash \
                 62274504032405607280124118774330643580776847808953813514882805671930016186964534250261993)))(Hash \
                 258298909772737723730677798993166714110497415306062417572062464892104545771985267258349270))(Hash \
                 128657935917879957925430358432862338350357215255689517583527581437261824609300184788378904)))(Hash \
                 304803933704609454671597295882678844943255413521392831551880538668562324084911415876416554))(Hash \
                 34716489672385656464039098696979776203828884915624905463163311924336703952733666467293590))(Hash \
                 453391292966349892782784198844803734791294851069777860262797017840584165118136896541838579))(Hash \
                 40068055375599075525408590868582141971990627294418472592764268063347061449424947733064228))(Hash \
                 462169888913782744344494602498101148830776264773152902647721267724193193548998068274279703))(Hash \
                 218232329225456815622314634592214769314720401120159872520750979659629083425174596321337082))(Hash \
                 230299270339465905136909281169312398251017393888312438856505396227938054043574555939373169))(Hash \
                 191568121862165683880053790997251957365896515586795375210646018121762652288877340159236289))(Hash \
                 110067368752222131191848831583370963803395988252764994023066298101161624067782936179657704))(Hash \
                 201806942395693728042861476088353179000123588841877514400843743397037515905097120081808255))(Hash \
                 229691137333347708260510158655457675236647271689304807453474943495785271308838363703382009))(Hash \
                 223015184774510446136762750994014335565258230518107717011034743340615899972010560899236599))(Hash \
                 77646474863893766150210302274475864090464981806645874026083765826256960091552818618132048))(Hash \
                 211739695889484249792559936114383614316669298717447584330325514353126637960163892766934699))(Hash \
                 94203441569507659406493681867549912249356996732509675907779226884956673221130828014951288))(Hash \
                 167422462382047340515233039616422786254896922616414889086602914546126188928277203444402233))(Hash \
                 207930886130202563864025624234219008000081693706035700489216887577707703594192264820327062))(Hash \
                 4945305625284184960806957761664016159547416717156203392904916313153202137335115016395135))(Hash \
                 347723055342077047176686195125510558109268207249937206782290329405114314596752785918573582))(Hash \
                 327560833736021510161866208550876896924359180547999719226423428664511452065796659584193932))(Hash \
                 347082227323324672106299442980653958669658736710382511315339222079516747929219876702414472))(Hash \
                 362466066878099229544218724775371558998735078940385472204842829411816549685310415832085359))(Hash \
                 469658926157591191112052026307778298010113022265825775419415298433917629974182391687945407))(Hash \
                 202736931892585559615186176284815371193091667348761538450087637332716942184897507583754259))(Hash \
                 58053664927027475802338970214937894252732182579838007296213346463827864446647552339802852))))"
                Sparse_ledger.t_of_sexp } )
    in
    input
    |> perform_single w
         ~message:
           (Coda_base.Sok_message.create ~fee:Currency.Fee.zero
              ~prover:Public_key.empty)
    |> Or_error.ok_exn |> ignore

  [%%endif]
end

module Worker = Worker.Make (Inputs)
