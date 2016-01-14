(*
 * Copyright (C) 2013 Citrix Inc
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
 * REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
 * INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
 * LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 *)
module FromBlock = Error.FromBlock

open Sexplib.Std
open Qcow
open Lwt
open OUnit
open Utils


let expect_ok = function
  | `Error _ -> failwith "IO failure"
  | `Ok x -> x

(* qemu-img will set version = `Three and leave an extra cluster
   presumably for extension headers *)

let read_write_header name size =
  let module B = Qcow.Make(Ramdisk) in
  let t =
    Ramdisk.connect name
    >>= fun x ->
    let ramdisk = expect_ok x in

    B.create ramdisk size
    >>= fun x ->
    let b = expect_ok x in

    let page = Io_page.(to_cstruct (get 1)) in
    Ramdisk.read ramdisk 0L [ page ]
    >>= fun x ->
    let () = expect_ok x in
    let open Error in
    match Qcow.Header.read page with
    | Result.Error (`Msg m) -> failwith m
    | Result.Ok (hdr, _) ->
      Lwt.return hdr in
  Lwt_main.run t

let additional = Some {
  Qcow.Header.dirty = true;
  corrupt = false;
  lazy_refcounts = true;
  autoclear_features = 0L;
  refcount_order = 4l;
}

let create_1K () =
  let hdr = read_write_header "1K" 1024L in
  let expected = {
    Qcow.Header.version = `Three; backing_file_offset = 0L;
    backing_file_size = 0l; cluster_bits = 16l; size = 1024L;
    crypt_method = `None; l1_size = 1l; l1_table_offset = 131072L;
    refcount_table_offset = 65536L; refcount_table_clusters = 1l;
    nb_snapshots = 0l; snapshots_offset = 0L; additional;
    extensions = [];
  } in
  let cmp a b = Qcow.Header.compare a b = 0 in
  let printer = Qcow.Header.to_string in
  assert_equal ~printer ~cmp expected hdr

let create_1M () =
  let hdr = read_write_header "1M" 1048576L in
  let expected = {
    Qcow.Header.version = `Three; backing_file_offset = 0L;
    backing_file_size = 0l; cluster_bits = 16l; size = 1048576L;
    crypt_method = `None; l1_size = 1l; l1_table_offset = 131072L;
    refcount_table_offset = 65536L; refcount_table_clusters = 1l;
    nb_snapshots = 0l; snapshots_offset = 0L; additional;
    extensions = [];
  } in
  let cmp a b = Qcow.Header.compare a b = 0 in
  let printer = Qcow.Header.to_string in
  assert_equal ~printer ~cmp expected hdr

let mib = Int64.mul 1024L 1024L
let gib = Int64.mul mib 1024L
let tib = Int64.mul gib 1024L
let pib = Int64.mul tib 1024L

let create_1P () =
  let hdr = read_write_header "1P" pib in
  let expected = {
    Qcow.Header.version = `Three; backing_file_offset = 0L;
    backing_file_size = 0l; cluster_bits = 16l; size = pib;
    crypt_method = `None; l1_size = 2097152l; l1_table_offset = 131072L;
    refcount_table_offset = 65536L; refcount_table_clusters = 1l;
    nb_snapshots = 0l; snapshots_offset = 0L; additional;
    extensions = [];
  } in
  let cmp a b = Qcow.Header.compare a b = 0 in
  let printer = Qcow.Header.to_string in
  assert_equal ~printer ~cmp expected hdr

let boundaries cluster_bits =
  let cluster_size = Int64.shift_left 1L cluster_bits in
  let pointers_in_cluster = Int64.(div cluster_size 8L) in [
    "0", 0L;
    Printf.sprintf "one %Ld byte cluster" cluster_size, cluster_size;
    Printf.sprintf "one L2 table (containing %Ld 8-byte pointers to cluster)"
      pointers_in_cluster,
    Int64.(mul cluster_size pointers_in_cluster);
    Printf.sprintf "one L1 table (containing %Ld 8-byte pointers to L2 tables)"
      pointers_in_cluster,
    Int64.(mul (mul cluster_size pointers_in_cluster) pointers_in_cluster)
  ]

let sizes sector_size cluster_bits = [
  "one sector", Int64.of_int sector_size;
  "one page", 4096L;
  "one cluster", Int64.shift_left 1L cluster_bits;
]

let off_by ((label', offset'), (label, offset)) = [
  label, offset;
  label ^ " + " ^ label', Int64.add offset offset';
  label ^ " - " ^ label', Int64.sub offset offset';
  label ^ " + 2 * " ^ label', Int64.(add offset (mul 2L offset'));
]

let rec cross xs ys = match xs, ys with
  | [], ys -> []
  | x :: xs, ys -> List.map (fun y -> x, y) ys @ (cross xs ys)

(* Parameterise over sector, page, cluster, more *)
let interesting_ranges sector_size size_sectors cluster_bits =
  let size_bytes = Int64.(mul size_sectors (of_int sector_size)) in
  let starts = List.concat (List.map off_by (cross (sizes sector_size cluster_bits) (boundaries cluster_bits))) in
  let all = starts @ (List.map (fun (label, offset) -> label ^ " from the end", Int64.sub size_bytes offset) starts) in
  (* add lengths *)
  let all = List.map (fun ((label', length'), (label, offset)) ->
      label' ^ " @ " ^ label, offset, length'
    ) (cross (sizes sector_size cluster_bits) all) in
  List.filter
    (fun (label, offset, length) ->
       offset >= 0L && (Int64.add offset length <= size_bytes)
    ) all

let get_id =
  let next = ref 1 in
  fun () ->
    let this = !next in
    incr next;
    this

let malloc (length: int) =
  let npages = (length + 4095)/4096 in
  Cstruct.sub Io_page.(to_cstruct (get npages)) 0 length

let rec fragment into remaining =
  if into >= Cstruct.len remaining
  then [ remaining ]
  else
    let this = Cstruct.sub remaining 0 into in
    let rest = Cstruct.shift remaining into in
    this :: (fragment into rest)

let read_write sector_size size_sectors (start, length) () =
  let module B = Qcow.Make(Ramdisk) in
  let t =
    Ramdisk.destroy ~name:"test";
    Ramdisk.connect "test"
    >>= fun x ->
    let ramdisk = expect_ok x in
    B.create ramdisk Int64.(mul size_sectors (of_int sector_size))
    >>= fun x ->
    let b = expect_ok x in

    let sector = Int64.div start 512L in
    let id = get_id () in
    let buf = malloc length in
    Cstruct.memset buf (id mod 256);
    B.write b sector (fragment 4096 buf)
    >>= fun x ->
    let () = expect_ok x in
    let buf' = malloc length in
    B.read b sector (fragment 4096 buf')
    >>= fun x ->
    let () = expect_ok x in
    let cmp a b = Cstruct.compare a b = 0 in
    assert_equal ~printer:(fun x -> String.escaped (Cstruct.to_string x)) ~cmp buf buf';

    (* This is the range that we expect to see written *)
    let expected = { Extent.start = sector; length = Int64.(div (of_int length) 512L) } in
    let ofs' = Int64.(mul sector (of_int sector_size)) in
    Mirage_block.fold_mapped_s
      ~f:(fun bytes_seen ofs data ->
          let actual = { Extent.start = ofs; length = Int64.of_int (Cstruct.len data / 512) } in
          (* Any data we read now which wasn't expected must be full of zeroes *)
          let extra = Extent.difference actual expected in
          List.iter
            (fun { Extent.start; length } ->
               let buf = Cstruct.sub data (512 * Int64.(to_int (sub start ofs))) (Int64.to_int length * 512) in
               for i = 0 to Cstruct.len buf - 1 do
                 assert_equal ~printer:string_of_int ~cmp:(fun a b -> a = b) 0 (Cstruct.get_uint8 buf i)
               done;
            ) extra;
          let common = Extent.intersect actual expected in
          List.iter
            (fun { Extent.start; length } ->
               let buf = Cstruct.sub data (512 * Int64.(to_int (sub start ofs))) (Int64.to_int length * 512) in
               for i = 0 to Cstruct.len buf - 1 do
                 assert_equal ~printer:string_of_int ~cmp:(fun a b -> a = b) (id mod 256) (Cstruct.get_uint8 buf i)
               done;
            ) common;
          let seen_this_time = 512 * List.(fold_left (+) 0 (map (fun e -> Int64.to_int e.Extent.length) common)) in
          return (`Ok (bytes_seen + seen_this_time))
        ) 0 (module B) b
    >>= fun x ->
    let total_bytes_seen = expect_ok x in
    assert_equal ~printer:string_of_int length total_bytes_seen;
    B.Debug.check_no_overlaps b
    >>= fun x ->
    let () = expect_ok x in
    Lwt.return () in
  Lwt_main.run t

let check_refcount_table_allocation () =
  let module B = Qcow.Make(Ramdisk) in
  let t =
    Ramdisk.destroy ~name:"test";
    Ramdisk.connect "test"
    >>= fun x ->
    let ramdisk = expect_ok x in
    B.create ramdisk pib
    >>= fun x ->
    let b = expect_ok x in

    let h = B.header b in
    let max_cluster = Int64.shift_right h.Header.size (Int32.to_int h.Header.cluster_bits) in
    B.Debug.set_next_cluster b (Int64.pred max_cluster);
    let length = 1 lsl (Int32.to_int h.Header.cluster_bits) in
    let sector = 0L in

    let buf = malloc length in
    B.write b sector (fragment 4096 buf)
    >>= fun x ->
    let () = expect_ok x in
    Lwt.return () in
  Lwt_main.run t

let check_full_disk () =
  let module B = Qcow.Make(Ramdisk) in
  let t =
    Ramdisk.destroy ~name:"test";
    Ramdisk.connect "test"
    >>= fun x ->
    let ramdisk = expect_ok x in
    B.create ramdisk gib
    >>= fun x ->
    let b = expect_ok x in

    B.get_info b
    >>= fun info ->

    let buf = malloc 512 in
    let h = B.header b in
    let sectors_per_cluster = Int64.(div (shift_left 1L (Int32.to_int h.Header.cluster_bits)) 512L) in
    let rec loop sector =
      if sector >= info.B.size_sectors
      then Lwt.return (`Ok ())
      else begin
        B.write b sector [ buf ]
        >>= fun x ->
        let () = expect_ok x in
        loop Int64.(add sector sectors_per_cluster)
      end in
    loop 0L
    >>= fun x ->
    let () = expect_ok x in
    Lwt.return () in
  Lwt_main.run t

(* Compare the output of this code against qemu *)
let virtual_sizes = [
  mib;
  gib;
  tib;
]

(* Create a temporary directory for our images. We want these to be
   manually examinable afterwards, so we give images human-readable names *)
let test_dir =
  (* a bit racy but if we lose, the test will simply fail *)
  let path = Filename.temp_file "ocaml-qcow" "" in
  Unix.unlink path;
  Unix.mkdir path 0o0755;
  debug "Creating temporary files in %s" path;
  path

let check_file path size =
  let info = Qemu.Img.info path in
  assert_equal ~printer:Int64.to_string size info.Qemu.Img.virtual_size;
  Qemu.Img.check path;
  let module M = Qcow.Make(Block) in
  let open FromBlock in
  Block.connect path
  >>= fun b ->
  M.connect b
  >>= fun qcow ->
  let h = M.header qcow in
  assert_equal ~printer:Int64.to_string size h.Qcow.Header.size;
  let open Lwt.Infix in
  M.disconnect qcow
  >>= fun () ->
  Block.disconnect b
  >>= fun () ->
  let open FromBlock in
  (* Check the qemu-nbd wrapper works *)
  Qemu.Block.connect path
  >>= fun block ->
  let open Lwt.Infix in
  Qemu.Block.get_info block
  >>= fun info ->
  let size = Int64.(mul info.Qemu.Block.size_sectors (of_int info.Qemu.Block.sector_size)) in
  assert_equal ~printer:Int64.to_string size size;
  Qemu.Block.disconnect block
  >>= fun () ->
  Lwt.return (`Ok ())

let qemu_img size =
  let path = Filename.concat test_dir (Int64.to_string size) in
  Qemu.Img.create path size;
  or_failwith @@ Lwt_main.run @@ check_file path size

let qemu_img_suite =
  List.map (fun size ->
      Printf.sprintf "check that qemu-img creates files and we can read the metadata, size = %Ld bytes" size >:: (fun () -> qemu_img size)
    ) virtual_sizes

let qcow_tool size =
  let open Lwt.Infix in
  let module B = Qcow.Make(Block) in
  let path = Filename.concat test_dir (Int64.to_string size) in

  let t =
    Lwt_unix.openfile path [ Unix.O_CREAT ] 0o0644
    >>= fun fd ->
    Lwt_unix.close fd
    >>= fun () ->
    let open FromBlock in
    Block.connect path
    >>= fun block ->
    B.create block size
    >>= fun qcow ->
    let open Lwt.Infix in
    B.disconnect qcow
    >>= fun () ->
    Block.disconnect block
    >>= fun () ->
    check_file path size in
  or_failwith @@ Lwt_main.run t

let qcow_tool_suite =
  List.map (fun size ->
      Printf.sprintf "check that qcow-tool creates files and we can read the metadata, size = %Ld bytes" size >:: (fun () -> qcow_tool size)
    ) virtual_sizes

let _ =
  let sector_size = 512 in
  (* Test with a 1 PiB disk, bigger than we'll need for a while. *)
  let size_sectors = Int64.div pib 512L in
  let cluster_bits = 16 in
  let interesting_writes = List.map
      (fun (label, start, length) -> label >:: read_write sector_size size_sectors (start, Int64.to_int length))
      (interesting_ranges sector_size size_sectors cluster_bits) in

  let suite = "qcow2" >::: [
      "check we can fill the disk" >:: check_full_disk;
      "check we can reallocate the refcount table" >:: check_refcount_table_allocation;
      "create 1K" >:: create_1K;
      "create 1M" >:: create_1M;
      "create 1P" >:: create_1P;
    ] @ interesting_writes @ qemu_img_suite @ qcow_tool_suite in
  OUnit2.run_test_tt_main (ounit2_of_ounit1 suite);
  (* If no error, delete the directory *)
  ignore(run "rm" [ "-rf"; test_dir ])
