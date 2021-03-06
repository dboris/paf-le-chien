let reporter ppf =
  let report src level ~over k msgf =
    let k _ = over () ; k () in
    let with_metadata header _tags k ppf fmt =
      Format.kfprintf k ppf ("%a[%a]: " ^^ fmt ^^ "\n%!")
        Logs_fmt.pp_header (level, header)
        Fmt.(styled `Magenta string) (Logs.Src.name src) in
    msgf @@ fun ?header ?tags fmt -> with_metadata header tags k ppf fmt in
  { Logs.report } 

let () = Mirage_crypto_rng_unix.initialize ()

(*
let () = Fmt_tty.setup_std_outputs ~style_renderer:`Ansi_tty ~utf_8:true ()
let () = Logs.set_reporter (reporter Fmt.stdout)
let () = Logs.set_level ~all:true (Some Logs.Debug)
*)

module Paf = Paf.Make(Time)(Tcpip_stack_socket)
module Ke = Ke.Rke

let getline queue =
  let exists ~predicate queue =
    let pos = ref 0 and res = ref (-1) in
    Ke.iter (fun chr -> if predicate chr then res := !pos ; incr pos) queue ;
    if !res = -1 then None else Some !res in
  let blit src src_off dst dst_off len =
    Bigstringaf.blit_to_bytes src ~src_off dst ~dst_off ~len in
  match exists ~predicate:((=) '\n') queue with
  | Some pos ->
    let tmp = Bytes.create pos in
    Ke.N.keep_exn queue ~blit ~length:Bytes.length ~off:0 ~len:pos tmp ;
    Ke.N.shift_exn queue (pos + 1) ;
    Some (Bytes.unsafe_to_string tmp)
  | None -> None

let http_large filename (ip, port) ic oc =
  Fmt.pr "<%a:%d> wants to receive large file.\n%!" Ipaddr.V4.pp ip port ;
  let open Httpaf in
  Body.close_reader ic ;
  let ic = open_in filename in
  let tp = Bytes.create 0x1000 in
  let rec go () = match input ic tp 0 (Bytes.length tp) with
    | 0 -> Body.close_writer oc
    | len ->
      Body.write_string oc (Bytes.sub_string tp 0 len) ; go ()
    | exception End_of_file -> Body.close_writer oc in
  go () ; close_in ic

let http_ping_pong (ip, port) ic oc =
  let open Httpaf in
  let open Lwt.Infix in
  let closed = ref false and queue = Ke.create ~capacity:0x1000 Bigarray.char in

  let blit src src_off dst dst_off len =
    Bigstringaf.blit src ~src_off dst ~dst_off ~len in
  let on_eof () = closed := true in
  let rec on_read buf ~off ~len =
    Fmt.epr "-> transmit %d byte(s).\n%!" len ;
    Ke.N.push queue ~blit ~length:Bigstringaf.length buf ~off ~len ;
    Body.schedule_read ic ~on_eof ~on_read in
  Body.schedule_read ic ~on_eof ~on_read ;
  let rec go () = match !closed, getline queue with
    | false, None -> Lwt.pause () >>= go
    | false, Some "ping" ->
      Body.write_string oc "pong\n" ; go ()
    | false, Some "pong" ->
      Body.write_string oc "ping\n" ; go ()
    | false, Some line ->
      Fmt.pr "<%a:%d> gaves a wrong line: %S.\n%!" Ipaddr.V4.pp ip port line ;
      Body.close_writer oc ; Lwt.return_unit
    | true, _ ->
      Fmt.pr "<%a:%d> closed the connection.\n%!" Ipaddr.V4.pp ip port ;
      Body.close_writer oc ; Lwt.return_unit in
  Lwt.async go

let request_handler large (ip, port) reqd =
  let open Httpaf in
  let request = Reqd.request reqd in
  match request.Request.target with
  | "/" ->
    Fmt.epr ">>> start a keep-alive connection.\n%!" ;
    let headers = Headers.of_list [ "transfer-encoding", "chunked" ] in
    let response = Response.create ~headers `OK in
    let oc = Reqd.respond_with_streaming reqd response in
    http_ping_pong (ip, port) (Reqd.request_body reqd) oc
  | "/ping" ->
    let headers = Headers.of_list [ "content-length", "4" ] in
    let response = Response.create ~headers `OK in
    Reqd.respond_with_string reqd response "pong"
  | "/pong" ->
    let headers = Headers.of_list [ "content-length", "4" ] in
    let response = Response.create ~headers `OK in
    Reqd.respond_with_string reqd response "ping"
  | "/large" ->
    let headers = Headers.of_list [ "transfer-encoding", "chunked" ] in
    let response = Response.create ~headers `OK in
    let oc = Reqd.respond_with_streaming reqd response in
    http_large large (ip, port) (Reqd.request_body reqd) oc
  | _ -> assert false

let error_handler (ip, port) ?request:_ error respond =
  let open Httpaf in match error with
  | `Exn (Paf.Send_error err)
  | `Exn (Paf.Recv_error err)
  | `Exn (Paf.Close_error err) ->
    let contents = Fmt.strf "Internal server error from <%a:%d>: %s" Ipaddr.V4.pp ip port err in
    let headers  = Headers.of_list
        [ "content-length", string_of_int (String.length contents) ] in
    let body = respond headers in
    Body.write_string body contents ;
    Body.close_writer body
  | _ -> ()

open Lwt.Infix

let ( >>? ) x f = x >>= function
  | Ok x -> f x
  | Error _ as err -> Lwt.return err

let server_http large stack =
  Conduit_mirage.serve
    ~key:Paf.TCP.configuration
    { Conduit_mirage_tcp.stack; keepalive= None; nodelay= false
    ; port= 8080; }
    ~service:Paf.TCP.service >>? fun (master, _) ->
  Paf.http ~error_handler ~request_handler:(request_handler large) master

let load_file filename =
  let ic = open_in filename in
  let ln = in_channel_length ic in
  let rs = Bytes.create ln in
  really_input ic rs 0 ln ;
  close_in ic ; Cstruct.of_bytes rs

let server_https cert key large stack =
  let cert = load_file cert in
  let key  = load_file key in
  match X509.Certificate.decode_pem_multiple cert,
        X509.Private_key.decode_pem key with
  | Ok certs, Ok (`RSA key) ->
    let config = Tls.Config.server ~certificates:(`Single (certs, key)) () in
    Conduit_mirage.serve
      ~key:Paf.tls_configuration
      ({ Conduit_mirage_tcp.stack; keepalive= None; nodelay= false
       ; port= 4343; }, config)
      ~service:Paf.tls_service >>? fun (master, _) ->
    Paf.https ~error_handler ~request_handler:(request_handler large) master
  | _ -> invalid_arg "Invalid certificate or key"

let stack ip =
  Tcpip_stack_socket.UDPV4.connect (Some ip) >>= fun udpv4 ->
  Tcpip_stack_socket.TCPV4.connect (Some ip) >>= fun tcpv4 ->
  Tcpip_stack_socket.connect [ ip ] udpv4 tcpv4

let run_http large =
  stack Ipaddr.V4.localhost >>= fun stack ->
  server_http large stack >>= function
  | Ok () -> Lwt.return_unit
  | Error err ->
    Fmt.epr "error: %a.\n%!" Conduit_mirage.pp_error err ;
    Lwt.return_unit

let run_https cert key large =
  stack Ipaddr.V4.localhost >>=
  server_https cert key large >>= function
  | Ok () -> Lwt.return_unit
  | Error err ->
    Fmt.epr "error: %a.\n%!" Conduit_mirage.pp_error err ;
    Lwt.return_unit

let () = match Sys.argv with
  | [| _; "--with-tls"; cert; key; large; |] ->
    Lwt_main.run (run_https cert key large)
  | [| _; large; |] ->
    Lwt_main.run (run_http large)
  | _ ->
    Fmt.epr "%s [--with-tls cert key] large\n%!" Sys.argv.(0)
