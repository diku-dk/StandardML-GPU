type fut_ctx = MLton.Pointer.t
type fut_i64_1d = MLton.Pointer.t
val futInit = _import "futInit" public : unit -> fut_ctx;
val futFinish = _import "futFinish" public : fut_ctx -> unit;
val rawFutSieve =
  _import "futSieve" public : fut_ctx * Int64.int * Int64.int array * Int64.int * Word8.word array -> unit;
val rawFutPrimes =
  _import "futPrimes" public : fut_ctx * Int64.int * Int64.int ref -> fut_i64_1d;
val rawFutReadValuesAndFree =
  _import "futReadValuesAndFree" public : fut_ctx * fut_i64_1d * Int64.int array -> unit;

fun doPrimesOnGpu ctx n =
  let
    val size = ref (0 : Int64.int)
    val futResult = rawFutPrimes (ctx, n, size)
    val count = !size
    val output = ForkJoin.alloc count
  in
    rawFutReadValuesAndFree (ctx, futResult, output);
    output
  end

fun doSieveOnGpu ctx n sqrtPrimes =
  let
    val numFlags = n + 1
    val flags: Word8.word array = ForkJoin.alloc numFlags
    fun isMarked i =
      Array.sub (flags, i) = 0w1
  in
    rawFutSieve (ctx, Array.length sqrtPrimes, sqrtPrimes, numFlags, flags);
    isMarked
  end


fun doSieveOnCpu _ n sqrtPrimes =
  let
    (* allocate array of flags to mark primes. *)
    val flags = ForkJoin.alloc (n + 1) : Word8.word array
    fun mark i = Array.update (flags, i, 0w1)
    fun unmark i = Array.update (flags, i, 0w0)
    fun isMarked i =
      Array.sub (flags, i) = 0w1

    (* initially, mark every number *)
    val _ = ForkJoin.parfor 10000 (0, n + 1) mark

    (* unmark every multiple of every prime in sqrtPrimes *)
    val _ = ForkJoin.parfor 1 (0, Array.length sqrtPrimes) (fn i =>
      let
        val p = Array.sub (sqrtPrimes, i)
        val numMultiples = n div p - 1
      in
        ForkJoin.parfor 4096 (0, numMultiples) (fn j => unmark ((j + 2) * p))
      end)
  in
    isMarked
  end


fun trace n prefix f =
  if true (*n < 10000*) then
    f ()
  else
    let
      val (result, tm) = Util.getTime f
    in
      print (prefix ^ " " ^ Time.fmt 4 tm ^ " (n = " ^ Int.toString n ^ ")\n");
      result
    end


fun primesOnGpuBenchmark {simultaneous: int, n: int} : int array array =
  let
    val ctx = futInit ()
    val result = Benchmark.run ("primes gpu") (fn _ =>
      SeqBasis.tabulate 1 (0, simultaneous) (fn _ => doPrimesOnGpu ctx n))
    val _ = futFinish ctx
  in
    result
  end


fun primesOnCpuBenchmark {simultaneous: int, n: int} : int array array =
  let
    fun primes ctx n =
      let
        fun loop n =
          if n < 2 then
            ForkJoin.alloc 0
          else
            let
              (* all primes up to sqrt(n) *)
              val sqrtPrimes = loop (Real.floor
                (Real.Math.sqrt (Real.fromInt n)))
              val isMarked = trace n "sieve:  " (fn _ =>
                doSieveOnCpu ctx n sqrtPrimes)
              val result = trace n "filter: " (fn _ =>
                SeqBasis.filter 4096 (2, n + 1) (fn i => i) isMarked)
            in
              result
            end

        val result = loop n
      in
        result
      end

    val ctx = ()
  in
    Benchmark.run ("primes cpu") (fn _ =>
      SeqBasis.tabulate 1 (0, simultaneous) (fn _ => primes ctx n))
  end


fun primesHybridBenchmark gpuThreshold {simultaneous: int, n: int} :
  int array array =
  let
    val gpuLock = SpinLock.new ()

    fun hybridSieve ctx n sqrtPrimes =
      if n >= gpuThreshold andalso SpinLock.trylock gpuLock then
        let val result = doSieveOnGpu ctx n sqrtPrimes
        in SpinLock.unlock gpuLock; result
        end
      else
        doSieveOnCpu ctx n sqrtPrimes


    fun hybridPrimes ctx n =
      let
        fun loop n =
          if n < 2 then
            ForkJoin.alloc 0
          else if n >= gpuThreshold andalso SpinLock.trylock gpuLock then
            let val result = doPrimesOnGpu ctx n
            in SpinLock.unlock gpuLock; result
            end
          else
            let
              (* all primes up to sqrt(n) *)
              val sqrtPrimes = loop (Real.floor
                (Real.Math.sqrt (Real.fromInt n)))
              val isMarked = trace n "sieve:  " (fn _ =>
                hybridSieve ctx n sqrtPrimes)
              val result = trace n "filter: " (fn _ =>
                SeqBasis.filter 4096 (2, n + 1) (fn i => i) isMarked)
            in
              result
            end

        val result = loop n
      in
        result
      end

    val ctx = futInit ()
    val result = Benchmark.run ("primes hybrid") (fn _ =>
      SeqBasis.tabulate 1 (0, simultaneous) (fn _ => hybridPrimes ctx n))
  in
    futFinish ctx;
    result
  end


val simultaneous = CommandLineArgs.parseInt "simultaneous" 1000
val n = CommandLineArgs.parseInt "n" (1000 * 1000)
val impl = CommandLineArgs.parseString "impl" "cpu"
val gpuThresh = CommandLineArgs.parseInt "gpu-thresh" 1000000

val _ = print ("simultaneous " ^ Int.toString simultaneous ^ "\n")
val _ = print ("n " ^ Int.toString n ^ "\n")
val _ = print ("impl " ^ impl ^ "\n")
val _ = print ("gpu-thresh " ^ Int.toString gpuThresh ^ "\n")

val bench =
  case impl of
    "cpu" => primesOnCpuBenchmark
  | "gpu" => primesOnGpuBenchmark
  | "hybrid" => primesHybridBenchmark gpuThresh
  | _ => Util.die ("unknown -impl " ^ impl)

val result = bench {simultaneous = simultaneous, n = n}
val result0 = Array.sub (result, 0)
val _ = print ("result " ^ Util.summarizeArray 8 Int.toString result0 ^ "\n")
val _ = print ("num primes " ^ Int.toString (Array.length result0) ^ "\n")
