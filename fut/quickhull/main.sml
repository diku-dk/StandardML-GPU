structure CLA = CommandLineArgs

val num_points = CLA.parseInt "n" 100000
val impl = CommandLineArgs.parseString "impl" "cpu"

fun rand i n =
  Int.fromLarge (Word64.toLargeInt (Word64.mod
    (Util.hash64 (Word64.fromInt i), Word64.fromInt n)))

fun randomPoints n =
  Seq.tabulate
    (fn i =>
       ( Real64.fromInt (rand i n) / Real64.fromInt n
       , Real64.fromInt (rand (i + 1) n) / Real64.fromInt n
       )) n

val ctx = Futhark.Context.new Futhark.default_cfg

fun quickhullCPU points =
  Quickhull.hull false (fn _ => raise Fail "No GPU for you") points

fun semihullGPU points_fut (idxs, l, r) =
  let
    val idxs' = Array.tabulate (Seq.length idxs, Int32.fromInt o Seq.nth idxs)
    val idxs_fut = Futhark.Int32Array1.new ctx idxs' (Seq.length idxs)
    val res_fut =
      Futhark.Entry.semihull ctx
        (points_fut, Int32.fromInt l, Int32.fromInt r, idxs_fut)
    val res = Futhark.Int32Array1.values res_fut
    val () = Futhark.Int32Array1.free res_fut
    val () = Futhark.Int32Array1.free idxs_fut
  in
    Seq.map Int32.toInt (Seq.fromArraySeq (ArraySlice.full res))
  end

fun quickhullHybrid points points_fut =
  let
    (* FIXME: Need a much better heuristic here. *)
    val (lower, upper) = (1000, Seq.length points div 128)
    fun useGPU (idxs, l, r) =
      Seq.length idxs >= lower andalso Seq.length idxs <= upper
  in
    Quickhull.hull true (semihullGPU points_fut) points
  end

fun quickhullGPU points_fut =
  let
    val res_fut = Futhark.Entry.quickhull ctx points_fut
    val res = Futhark.Int32Array1.values res_fut
    val () = Futhark.Int32Array1.free res_fut
  in
    Seq.map Int32.toInt (Seq.fromArraySeq (ArraySlice.full res))
  end

val () = print
  ("Generating " ^ Int.toString num_points ^ " random uniform points.\n")
val points = randomPoints num_points

val points_fut =
  let
    val points_arr = Array.tabulate (Seq.length points * 2, fn i =>
      let val (x, y) = Seq.nth points (i div 2)
      in if i mod 2 = 0 then x else y
      end)
  in
    Futhark.Real64Array2.new ctx points_arr (Seq.length points, 2)
  end

val bench =
  case impl of
    "cpu" => (fn () => quickhullCPU points)
  | "gpu" => (fn () => quickhullGPU points_fut)
  | "hybrid" => (fn () => quickhullHybrid points points_fut)
  | _ => Util.die ("unknown -impl " ^ impl)

val result = Benchmark.run ("quickhull " ^ impl) bench

val () = Futhark.Real64Array2.free points_fut
val () = Futhark.Context.free ctx
val () = print
  ("Indexes of points in convex hull:\n" ^ Seq.toString Int.toString result
   ^ "\n")
