module F = import "lib/github.com/porcuquine/fut-ff/field"

import "lib/github.com/athas/vector/vector"
module vector_2 = cat_vector vector_1 vector_1
module vector_3 = cat_vector vector_2 vector_1
module vector_4 = cat_vector vector_2 vector_2

-- For some reason, we can't access these bls12_381-related definitison from fut-ff/field, so just repeat here.
-- https://github.com/filecoin-project/pairing/blob/master/src/bls12_381/fr.rs#L9
-- #[PrimeFieldModulus = "52435875175126190479447740508185965837690552500527637822603658699938581184513"]
let bls12_381_modulus  = "52435875175126190479447740508185965837690552500527637822603658699938581184513"
let r_squared_mod_p =  "3294906474794265442129797520630710739278575682199800681788903916070560242797"

module bls12_381: F.field = F.big_field (F.fieldtype u64 {
                                                       module LVec = vector_4
                                                       let limbs = 4i32
                                                       let p () = copy bls12_381_modulus
                                                       let r2 () = copy r_squared_mod_p })

type option 't = #Some(t) | #None

module type Params = {
  val arity: i32
  val full_rounds: i32
  val partial_rounds: i32
}

type matrix 't [width] = [width][width] t

type sparse_matrix 't [width] [width_] = {
    w_hat: [width]t,
    v_rest: [width_]t
}

type sparse_matrix_in 't [n] = [n]t


type constants 't [width] [width_] [rk_count] [sparse_count]= {
    arity_tag: t,
    round_keys: [rk_count]t,
    mds_matrix: matrix t [width],
    pre_sparse_matrix: matrix t [width],
    sparse_matrixes: [sparse_count]sparse_matrix t [width] [width_]
}

module type hasher  = {
  module Field: F.field

  type state

  val width: i32
  val arity: i32
  val width_: i32
  val rk_count: i32
  val sparse_count: i32
  val sparse_matrix_size: i32

  val init: (constants: constants Field.t [width] [width_] [rk_count] [sparse_count]) -> state
  val blank_constants: constants Field.t [width] [width_] [rk_count] [sparse_count]

  val constants: state -> constants Field.t [width] [width_] [rk_count] [sparse_count]

  val set_preimage: state -> [arity]Field.t -> state
  val hash: state -> Field.t
  val hash_preimage: state -> [arity]Field.t -> Field.t

  val reset: state -> state

  val leaves_per_kib: i32 -> i32
  val leaves_per_mib: i32 -> i32
  val leaves_per_gib: i32 -> i32

  val make_constants: [Field.LIMBS]u64 -> [rk_count][Field.LIMBS]u64 -> matrix ([Field.LIMBS]u64) [width] -> matrix ([Field.LIMBS]u64) [width] -> [sparse_count][sparse_matrix_size][Field.LIMBS]u64 -> constants (Field.t) [width] [width_] [rk_count] [sparse_count]
}

module make_hasher (f: F.field) (p: Params): hasher = {
  module Field = f

  let arity = p.arity
  let width = arity + 1
  let width_ = width - 1 -- width *could* be other than 1 + arity.
  let full_rounds = p.full_rounds
  let partial_rounds = p.partial_rounds
  let rk_count = width * p.full_rounds + p.partial_rounds -- TODO: Check this. We'll find out if it's wrong when integrating, of course.
  let sparse_count = p.partial_rounds -- TODO: check
  let sparse_matrix_size = width + width_

  let full_half = assert (full_rounds % 2 == 0) full_rounds / 2
  let sparse_offset = full_half - 1

  type elements = [width]Field.t
  type mat = matrix Field.t [width]
  type s_mat = sparse_matrix Field.t [width] [width_]

  type state = {
      constants: constants Field.t [width] [width_] [rk_count] [sparse_count],
      elements: elements,
      current_round: i32,
      rk_offset: i32
  }

  let init (constants: constants Field.t [width] [width_] [rk_count] [sparse_count]): state = {
      constants,
      elements = map (\i -> if i == 0 then constants.arity_tag else Field.zero) (iota width),
      current_round = 0,
      rk_offset = 0
  }

  let mk_arity_tag (arity: i32): Field.t  = Field.from_u32 (u32.i32 (1 << arity))

  let blank_constants: constants Field.t [width] [width_] [rk_count] [sparse_count] =
    let dummy = Field.from_string "123" in -- dummy value for now, don't use 0 or 1, so we get hash-like results.
    let arity_tag = mk_arity_tag arity
    let round_keys = map (\_ -> dummy) (iota rk_count) :> [rk_count]Field.t in
    let mds_matrix = map (\_i -> map (\_j -> dummy) (iota width)) (iota width)
    let pre_sparse_matrix =  map (\_i -> map (\_j -> dummy) (iota width)) (iota width)
    let sparse_matrixes = map (\_ -> { w_hat = map (\_ -> dummy) (iota width),
                                       v_rest = map (\_ -> dummy) (iota width_) })
                              (iota sparse_count) in
    { arity_tag,
      round_keys,
      mds_matrix,
      pre_sparse_matrix,
      sparse_matrixes }

  let make_sparse_matrix (array: [sparse_matrix_size]Field.t): sparse_matrix Field.t [width] [width_] =
    { w_hat = take width array,
      v_rest = take width_ <| drop width <| array }

  let make_constants (arity_tag: ([Field.LIMBS]u64)) (round_keys: [rk_count]([Field.LIMBS]u64)) (mds_matrix: matrix ([Field.LIMBS]u64) [width]) (pre_sparse_matrix: matrix ([Field.LIMBS]u64) [width])
  (sparse_matrixes: [sparse_count][sparse_matrix_size][Field.LIMBS]u64): constants Field.t [width] [width_] [rk_count] [sparse_count] =
    let sparse_matrixes = map make_sparse_matrix (map (map Field.from_u64s) sparse_matrixes) in
    { arity_tag = Field.from_u64s arity_tag,
      round_keys = map Field.from_u64s round_keys,
      mds_matrix = map (map Field.from_u64s) mds_matrix,
      pre_sparse_matrix = map (map Field.from_u64s) pre_sparse_matrix,
      sparse_matrixes }

  let reset (s: state): state = s with current_round = 0
                                  with rk_offset = 0
                                  with elements = map (\i -> if i == 0 then s.constants.arity_tag else Field.zero) (iota width)

  let constants (s: state): constants Field.t [width] [width_] [rk_count] [sparse_count] = s.constants

  let set_preimage (s: state) (preimage: [arity]Field.t): state =
    s with elements = (([s.constants.arity_tag] ++ preimage) :> elements)

  let result (s: state): Field.t = s.elements[1]

  -- Placeholder until Field.square is fixed.
  let fake_square (x: Field.t): Field.t = Field.(x * x)

  let quintic_s_box (x: Field.t): Field.t =
    let x2 = fake_square x in
    let x4 = fake_square x2 in
    Field.(x4 * x)

  let add_round_key (s: state) (rk_offset: i32) (i: i32) =
    let elts = s.elements in
    let round_keys = s.constants.round_keys in
    Field.(elts[i] + round_keys[rk_offset i32.+ i])

  -- Could be more generic, but could also use a library. Just target clarity.
  let scalar_product (a: elements) (b: elements) = Field.(reduce (+) zero (map2 (*) a b))

  let apply_matrix (m: mat) (elts: elements): elements =
    map (scalar_product elts) (transpose m)

  let apply_sparse_matrix (sm: s_mat) (elts: [width]Field.t): elements =
    let first = scalar_product elts sm.w_hat
    let rest = map2 (\x y -> Field.(x + y * elts[0]))
                    (elts[1:width] :> [width_]Field.t)
                    sm.v_rest in
    ([first] ++ rest) :> elements

  let apply_round_matrix (s: state): state =
    let elements = if s.current_round == sparse_offset then
                     apply_matrix s.constants.pre_sparse_matrix s.elements
                   else if (s.current_round > sparse_offset)
                           && (s.current_round < full_half + partial_rounds) then
                        let index = s.current_round - sparse_offset - 1 in
                        apply_sparse_matrix  s.constants.sparse_matrixes[index] s.elements
                   else
                     apply_matrix  s.constants.mds_matrix s.elements in
      s with elements = elements

  let add_full_round_keys (s: state): state =
     s with elements = map (\i -> add_round_key s s.rk_offset i) (iota width)
       with rk_offset = s.rk_offset + width

  let add_partial_round_key (s: state): state =
    s with elements = map (\i -> if i == 0 then add_round_key s s.rk_offset i else s.elements[i]) (iota width)
      with rk_offset = s.rk_offset + 1

  let full_round (s: state): state =
    let elements = map quintic_s_box s.elements in
    let s = add_full_round_keys s with elements = elements in
    apply_round_matrix s
      with current_round = s.current_round + 1

  let last_full_round (s: state): state =
    let elements = map quintic_s_box s.elements in
    s with elements = elements
      with current_round = s.current_round + 1

  let partial_round (s: state): state =
    let elements = copy s.elements with [0] = quintic_s_box s.elements[0] in
    let s = add_partial_round_key s with elements = elements in
    apply_round_matrix s with current_round = s.current_round + 1

  let hash (s: state): Field.t =
    let s = add_full_round_keys s in
    let s = loop s for _i < full_half do full_round s in
    let s = loop s for _i < partial_rounds do partial_round s in
    let s = loop s for _i < (full_half - 1) do full_round s in
    let s = last_full_round s in
    result s

  let hash_preimage (s: state) (preimage: [arity]Field.t) =
    hash (set_preimage s preimage)

  -- FIXME: this assumes 32-byte leaves, but we should actually get the element width (rounded up to nearest byte) from the hasher.
  let leaves_per_kib (kib: i32) =
    kib * 1024 / 32

  let leaves_per_mib (mib: i32) =
    mib * 1024 * 1024 / 32

  let leaves_per_gib (gib: i32) =
    i32.u64 ((u64.i32 gib) * 1024 * 1024 * 1024 / 32)
}

module type tree_builder = {
  module Hasher: hasher

  val leaves: i32
  val height: i32
  val tree_size: i32

  val build_tree:  Hasher.state -> [leaves]Hasher.Field.t -> [tree_size]Hasher.Field.t
  val compute_root: Hasher.state -> [leaves]Hasher.Field.t -> Hasher.Field.t
}

module type tree_builder_params = {
--  module Hasher: hasher
  val leaves: i32
}

module make_tree_builder (H: hasher)   (P: tree_builder_params): tree_builder = {
  module Hasher = H
  module Field = Hasher.Field
  type t = Field.t

  let zero = Field.zero

  let leaves = P.leaves
  let arity = Hasher.arity

  let tree_dimensions (leaves: i32) (arity: i32): (i32, i32) =
    let (height, size, _) = loop (height, size, row_size) = (0, leaves, leaves) while row_size > 1 do
    let new_row_size = assert (row_size % arity == 0) row_size/arity in
    (height + 1, size + new_row_size, new_row_size)

    in (height, size)

  let dimensions = tree_dimensions leaves arity
  let height = dimensions.0
  let tree_size = dimensions.1

  -- Like build_tree but does not retain intermediate results.
  let compute_root (s: Hasher.state) (base: [leaves]t): t =
    let l = length base in
    let chunks = assert (l % arity == 0) l / arity in
    -- Base shrinks by a factor of 1/Hasher.arity on each iteration.
    let nodes = loop base while length base > 1 do
                  map  (\preimage -> (Hasher.hash_preimage s preimage))
                      (unflatten chunks Hasher.arity base)
    in assert (length nodes == 1) nodes[0]

  -- Like compute_root but returns an array of all rows, not just the last.
  -- This includes the original base row in the final treee, but to minimize memory, maybe we should define it not to.
  let build_tree (s: Hasher.state) (base: [leaves]t): [tree_size]t =
  let l = length base in
    let chunks = assert (l % arity == 0) l / arity in
    -- Row shrinks by a factor of 1/Hasher.arity on each iteration.
    let (tree, _, _)
    = loop (tree, row, offset) =
        ((replicate tree_size Field.zero) with [0:(length base)] = base,
         base,
         0)
      while length row > 1 do
        let new_row = map (\preimage -> (Hasher.hash_preimage s preimage))
                          (unflatten chunks Hasher.arity base) in
        (tree with [offset:offset+length new_row] = new_row,
         new_row,
         offset + length new_row)
    in tree
}

module type column_tree_builder = {
  module ColumnHasher: hasher
  module TreeBuilder: tree_builder

  type state

  val column_size: i32 -- elements per column

  val init: ColumnHasher.state -> TreeBuilder.Hasher.state -> state
  val reset: state -> state
  val add_columns: state -> (chunk_size: i32) -> [chunk_size]ColumnHasher.Field.t -> state
  val finalize: state -> [TreeBuilder.tree_size]TreeBuilder.Hasher.Field.t
}

module make_column_tree_builder (ColumnHasher: hasher) (TreeBuilder: tree_builder): column_tree_builder = {
  module ColumnHasher = ColumnHasher
  module TreeBuilder = TreeBuilder

  type state = {
      column_state: ColumnHasher.state,
      tree_hasher_state: TreeBuilder.Hasher.state,
      leaves: [TreeBuilder.leaves]ColumnHasher.Field.t,
      pos: i32
  }

  let column_size = ColumnHasher.arity

  let init (column_state: ColumnHasher.state) (tree_hasher_state: TreeBuilder.Hasher.state): state =
    { column_state = copy column_state,
      tree_hasher_state = copy tree_hasher_state,
      leaves = replicate TreeBuilder.leaves ColumnHasher.Field.zero,
      pos = 0}

  let reset (s: state): state =
    s with column_state = ColumnHasher.reset s.column_state
      with tree_hasher_state = TreeBuilder.Hasher.reset s.tree_hasher_state
      with leaves = replicate TreeBuilder.leaves ColumnHasher.Field.zero
      with pos = 0

  let add_columns (s: state) (chunk_size: i32) (flat_columns: [chunk_size]ColumnHasher.Field.t): state =
    let columns = unflatten chunk_size ColumnHasher.arity flat_columns in
    let column_leaves = (map (ColumnHasher.hash_preimage (copy s.column_state)) columns) in
    let new_pos = s.pos + (length column_leaves) in
    s with leaves = (copy s.leaves with [s.pos:new_pos] = column_leaves)
      with pos = new_pos

  let finalize (s: state): [TreeBuilder.tree_size]TreeBuilder.Hasher.Field.t =
    let leaves = map (\i -> TreeBuilder.Hasher.Field.from_u64s (ColumnHasher.Field.to_u64s s.leaves[i])) (iota TreeBuilder.leaves) in
    (TreeBuilder.build_tree s.tree_hasher_state leaves)
}

--------------------------------------------------------------------------------

module p2: hasher = make_hasher bls12_381 { let arity = 2i32
                                            let full_rounds = 8i32
                                            let partial_rounds = 55i32 }

module p4: hasher = make_hasher bls12_381 { let arity = 4i32
                                            let full_rounds = 8i32
                                            let partial_rounds = 56i32 }

module p8: hasher = make_hasher bls12_381 { let arity = 8i32
                                            let full_rounds = 8i32
                                            let partial_rounds = 57i32 }

module p11: hasher = make_hasher bls12_381 {
  let arity = 11i32
  let full_rounds = 8i32
  let partial_rounds = 57i32 }

module t2_2k: tree_builder =  make_tree_builder p2 { let leaves: i32 = p2.leaves_per_kib 2 }
module t4_2k: tree_builder =  make_tree_builder p4 { let leaves: i32 = p4.leaves_per_kib 2 }
module t8_2k: tree_builder =  make_tree_builder p8 { let leaves: i32 = p8.leaves_per_kib 2 }

module t8_512m: tree_builder =  make_tree_builder p8 { let leaves: i32 = p8.leaves_per_mib 512 }
module t8_4g: tree_builder =  make_tree_builder p8 { let leaves: i32 = p8.leaves_per_gib 4 }

let x2 = p2.init p2.blank_constants
entry simple2 n = tabulate n (\i -> p2.Field.to_u64s (p2.hash_preimage x2 ((replicate 2 (p2.Field.from_u32 (u32.i32 i))) :> [p2.arity]p2.Field.t)))

let x8 = p8.init p8.blank_constants
entry simple8 n = tabulate n (\i -> p8.Field.to_u64s (p8.hash_preimage x8 ((replicate 8 (p8.Field.from_u32 (u32.i32 i))) :> [p8.arity]p8.Field.t)))

let x11 = p11.init p11.blank_constants
entry simple11 n = tabulate n (\i -> p11.Field.to_u64s (p11.hash_preimage x11 ((replicate 11 (p11.Field.from_u32 (u32.i32 i))) :> [p11.arity]p11.Field.t)))

--------------------------------------------------------------------------------
--- Primary interface
--
-- This hardcodes:
-- Column arity = 11
-- Tree arity   = 8
-- Tree size    = 4 GiB

module ctb = make_column_tree_builder p11 t8_4g

module colhasher = ctb.ColumnHasher
module treehasher = ctb.TreeBuilder.Hasher

entry init (treehasher_arity_tag: ([treehasher.Field.LIMBS]u64))
           (treehasher_round_keys: [treehasher.rk_count]([treehasher.Field.LIMBS]u64))
           (treehasher_mds_matrix: matrix ([treehasher.Field.LIMBS]u64) [treehasher.width])
           (treehasher_pre_sparse_matrix: matrix ([treehasher.Field.LIMBS]u64) [treehasher.width])
           (treehasher_sparse_matrixes: [treehasher.sparse_count][treehasher.sparse_matrix_size]([treehasher.Field.LIMBS]u64))
           (colhasher_arity_tag: ([colhasher.Field.LIMBS]u64))
           (colhasher_round_keys: [colhasher.rk_count]([colhasher.Field.LIMBS]u64))
           (colhasher_mds_matrix: matrix ([colhasher.Field.LIMBS]u64) [colhasher.width])
           (colhasher_pre_sparse_matrix: matrix ([colhasher.Field.LIMBS]u64) [colhasher.width])
           (colhasher_sparse_matrixes: [colhasher.sparse_count][colhasher.sparse_matrix_size]([colhasher.Field.LIMBS]u64))
           : ctb.state =
  let treehasher_constants = treehasher.make_constants treehasher_arity_tag treehasher_round_keys treehasher_mds_matrix treehasher_pre_sparse_matrix treehasher_sparse_matrixes in
  let colhasher_constants =   colhasher.make_constants colhasher_arity_tag colhasher_round_keys colhasher_mds_matrix colhasher_pre_sparse_matrix colhasher_sparse_matrixes in
  ctb.init (colhasher.init colhasher_constants) (treehasher.init treehasher_constants)

entry add_columns (s: ctb.state) (chunk_size: i32) (columns: []u64): ctb.state =
  ctb.add_columns s chunk_size (map colhasher.Field.from_u64s (unflatten chunk_size colhasher.arity  columns))

entry finalize (s: ctb.state): [ctb.TreeBuilder.tree_size]treehasher.Field.t =
  ctb.finalize s