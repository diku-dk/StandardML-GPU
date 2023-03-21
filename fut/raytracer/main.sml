structure CLA = CommandLineArgs

val height = CLA.parseInt "h" 200
val width = CLA.parseInt "w" 200
val output = CLA.parseString "output" ""
val dop6 = CLA.parseFlag "ppm6"
val scene_name = CLA.parseString "s" "rgbbox"
val scene =
  case scene_name of
    "rgbbox" => Ray.rgbbox
  | "irreg" => Ray.irreg
  | s => raise Fail ("No such scene: " ^ s)

val ctx = FutRay.init ()

val _ = print ("h " ^ Int.toString height ^ "\n")
val _ = print ("w " ^ Int.toString width ^ "\n")
val _ = print ("output " ^ (if output = "" then "(none)" else output) ^ "\n")
val _ = print ("ppm6? " ^ (if dop6 then "yes" else "no") ^ "\n")
val _ = print ("s " ^ scene_name ^ "\n")

val ((objs, cam), tm1) = Util.getTime (fn _ =>
  Ray.from_scene width height scene)
val _ = print ("Scene BVH construction in " ^ Time.fmt 4 tm1 ^ "s\n")

val prepared_scene = FutRay.prepare_rgbbox_scene (ctx, height, width)

val result = Benchmark.run "rendering" (fn _ =>
  Ray.render ctx prepared_scene objs width height cam)

val _ = FutRay.prepare_rgbbox_scene_free (ctx, prepared_scene)
val _ = FutRay.cleanup ctx

val writeImage = if dop6 then Ray.image2ppm6 else Ray.image2ppm

val _ =
  if output <> "" then
    let
      val out = TextIO.openOut output
    in
      print ("Writing image to " ^ output ^ ".\n");
      writeImage out (result);
      TextIO.closeOut out
    end
  else
    print ("-output not passed, so not writing image to file.\n")
