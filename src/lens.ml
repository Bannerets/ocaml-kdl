open Ast

(* we can replace option with result for more detailed errors *)

type ('a, 'b) lens = {
  get : 'a -> 'b option;
  set : 'b -> 'a -> 'a option;
}

let get a lens = lens.get a

let set a v lens = lens.set v a

let get_exn a lens = Option.get @@ lens.get a

let set_exn a v lens = Option.get @@ lens.set v a

(* update can be added to the definition of [lens] to increase performance with
   more specialized implementations *)

let update f a lens =
  match lens.get a with
  | None -> None
  | Some value -> match f value with
    | None -> None
    | Some value' -> lens.set value' a

let compose l1 l2 = {
  get = (fun x ->
    match l2.get x with
    | Some x' -> l1.get x'
    | None -> None
  );
  set = (fun v a -> update (l1.set v) a l2)
}

let (|--) l1 l2 = compose l2 l1

let (//) = (|--)

let (.@()) = get
let (.@()<-) a l v = set a v l

let node_name = {
  get = (fun node -> Some node.name);
  set = (fun name node -> Some { node with name })
}

let node_annot = {
  get = (fun node -> node.annot);
  set = (fun annot node -> Some { node with annot = Some annot })
}

(* Unset the annotation by passing None *)
let node_annot_opt = {
  get = (fun node -> Some node.annot);
  set = (fun annot node -> Some { node with annot })
}

let args = {
  get = (fun node -> Some node.args);
  set = (fun args node -> Some { node with args })
}

let props = {
  get = (fun node -> Some node.props);
  set = (fun props node -> Some { node with props })
}

let children = {
  get = (fun node -> Some node.children);
  set = (fun children node -> Some { node with children })
}

let top = {
  get = (function node :: _ -> Some node | [] -> None);
  set = (fun node -> function _ :: xs -> Some (node :: xs) | [] -> None)
}

let nth_and_replace n x' list =
  let found = ref false in
  (* Note: Unlike List.mapi, this stops iterating when we've found the element *)
  let[@tail_mod_cons] rec go i = function
    | [] -> []
    | _ :: xs when i = n -> found := true; x' :: xs
    | x :: xs -> x :: go (i + 1) xs
  in
  let result = go 0 list in
  if !found then Some result else None

let nth n = {
  get = (fun list -> List.nth_opt list n);
  set = (fun x' list -> nth_and_replace n x' list)
}

(* these operations are O(n), and update is quite inefficient *)
let arg n = {
  (* Inlined [nth] instead of [args |-- nth n] *)
  get = (fun node -> List.nth_opt node.args n);
  set = (fun arg' node -> match nth_and_replace n arg' node.args with
    | Some args -> Some { node with args }
    | None -> None)
}

let prop key = {
  get = (fun node -> List.assoc_opt key node.props);
  set = (fun v' node ->
    let found = ref false in
    let f (k, v) = if k = key then (found := true; k, v') else k, v in
    let props = List.map f node.props in
    if !found then Some { node with props } else None
  )
}

let find_and_replace f x' list =
  let f (found, xs) x =
    if not found && f x then
      true, x' :: xs
    else
      found, x :: xs in
  let found, list = List.fold_left f (false, []) list in
  if found then Some (List.rev list) else None

let filter_and_replace f replace_list list =
  let found = ref false in
  let f (replace, result) x =
    if f x then begin
      found := true;
      match replace with
      | x' :: xs -> xs, x' :: result
      | [] -> [], x :: result
    end else
      replace, x :: result
  in
  let _, list = List.fold_left f (replace_list, []) list in
  if !found then Some (List.rev list) else None

let matches_name ?annot name node =
  node.name = name && (match annot with
    | Some a -> (match node.annot with
      | Some a' -> a = a'
      | None -> false)
    | None -> true)

(* TODO: add a ?nth argument? *)
let node ?annot (name : string) =
  let matches = matches_name ?annot name in
  {
    get = (fun nodes -> List.find_opt matches nodes);
    set = (fun node' nodes -> find_and_replace matches node' nodes)
  }

let node_many ?annot (name : string) =
  let matches = matches_name ?annot name in
  {
    get = (fun nodes ->
      match List.filter matches nodes with [] -> None | xs -> Some xs);
    set = (fun nodes' nodes -> filter_and_replace matches nodes' nodes)
  }

let node_nth : int -> (node list, node) lens = nth

(* TODO: get node by annot only? *)

let child ?annot name = children |-- node ?annot name
let child_many ?annot name = children |-- node_many ?annot name
let child_nth n = children |-- node_nth n

let value : (annot_value, value) lens = {
  get = (fun (_, v) -> Some v);
  set = (fun v' (a, _) -> Some (a, v'))
}

let annot : (annot_value, string) lens = {
  get = (fun (a, _) -> a);
  set = (fun a' (_, v) -> Some (Some a', v))
}

let annot_opt : (annot_value, string option) lens = {
  get = (fun (a, _) -> Some a);
  set = (fun a' (_, v) -> Some (a', v))
}

let string = {
  get = (function `String str -> Some str | _ -> None);
  set = (fun value' _value -> Some (`String value'))
}

let int = {
  get = (function `Int v -> Some v | _ -> None);
  set = (fun value' _value -> Some (`Int value'))
}

let raw_int = {
  get = (function `RawInt v -> Some v | _ -> None);
  set = (fun value' _value -> Some (`RawInt value'))
}

let float = {
  get = (function `Float v -> Some v | _ -> None);
  set = (fun value' _value -> Some (`Float value'))
}

let number : (value, [`Int of int | `RawInt of string | `Float of float ]) lens = {
  get = (function `Int _ | `RawInt _ | `Float _ as v -> Some v | _ -> None);
  set = (fun v' _v -> Some (v' :> value))
}

let bool = {
  get = (function `Bool b -> Some b | _ -> None);
  set = (fun value' _value -> Some (`Bool value'))
}

let null = {
  get = (function `Null -> Some () | _ -> None);
  set = (fun _ _ -> Some `Null)
}

let string_value : (annot_value, string) lens = value |-- string
let int_value : (annot_value, int) lens = value |-- int
let raw_int_value : (annot_value, string) lens = value |-- raw_int
let float_value : (annot_value, float) lens = value |-- float
let bool_value : (annot_value, bool) lens = value |-- bool
let null_value : (annot_value, unit) lens = value |-- null

let filter f = {
  get = (fun list -> Some (List.filter f list));
  set = (fun replace list -> filter_and_replace f replace list)
}

exception Short_circuit

let mapm_option f list =
  let g a = match f a with Some x -> x | None -> raise_notrace Short_circuit in
  try Some (List.map g list)
  with Short_circuit -> None

let each l = {
  get = (fun list -> mapm_option l.get list);
  set = (fun replace_list list ->
    let f (replace, result) v =
      match replace with
      | v' :: replace_rest -> (match l.set v' v with
        | Some x -> replace_rest, x :: result
        | None -> raise_notrace Short_circuit)
      | [] -> [], v :: result
    in
    try
      let _, list = List.fold_left f (replace_list, []) list in
      Some (List.rev list)
    with Short_circuit -> None
  )
}
