(* Copyright (c) 2008, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure CoreUtil :> CORE_UTIL = struct

open Core

fun classifyDatatype xncs =
    if List.all (fn (_, _, NONE) => true | _ => false) xncs then
        Enum
    else
        Default

structure S = Search

structure Kind = struct

fun mapfold f =
    let
        fun mfk k acc =
            S.bindP (mfk' k acc, f)

        and mfk' (kAll as (k, loc)) =
            case k of
                KType => S.return2 kAll

              | KArrow (k1, k2) =>
                S.bind2 (mfk k1,
                      fn k1' =>
                         S.map2 (mfk k2,
                              fn k2' =>
                                 (KArrow (k1', k2'), loc)))

              | KName => S.return2 kAll

              | KRecord k =>
                S.map2 (mfk k,
                        fn k' =>
                           (KRecord k', loc))

              | KUnit => S.return2 kAll
    in
        mfk
    end

fun map f k =
    case mapfold (fn k => fn () => S.Continue (f k, ())) k () of
        S.Return () => raise Fail "Core_util.Kind.map"
      | S.Continue (k, ()) => k

fun exists f k =
    case mapfold (fn k => fn () =>
                             if f k then
                                 S.Return ()
                             else
                                 S.Continue (k, ())) k () of
        S.Return _ => true
      | S.Continue _ => false

end

structure Con = struct

datatype binder =
         Rel of string * kind
       | Named of string * int * kind * con option

fun mapfoldB {kind = fk, con = fc, bind} =
    let
        val mfk = Kind.mapfold fk

        fun mfc ctx c acc =
            S.bindP (mfc' ctx c acc, fc ctx)

        and mfc' ctx (cAll as (c, loc)) =
            case c of
                TFun (c1, c2) =>
                S.bind2 (mfc ctx c1,
                      fn c1' =>
                         S.map2 (mfc ctx c2,
                              fn c2' =>
                                 (TFun (c1', c2'), loc)))
              | TCFun (x, k, c) =>
                S.bind2 (mfk k,
                      fn k' =>
                         S.map2 (mfc (bind (ctx, Rel (x, k))) c,
                              fn c' =>
                                 (TCFun (x, k', c'), loc)))
              | TRecord c =>
                S.map2 (mfc ctx c,
                        fn c' =>
                           (TRecord c', loc))

              | CRel _ => S.return2 cAll
              | CNamed _ => S.return2 cAll
              | CFfi _ => S.return2 cAll
              | CApp (c1, c2) =>
                S.bind2 (mfc ctx c1,
                      fn c1' =>
                         S.map2 (mfc ctx c2,
                              fn c2' =>
                                 (CApp (c1', c2'), loc)))
              | CAbs (x, k, c) =>
                S.bind2 (mfk k,
                      fn k' =>
                         S.map2 (mfc (bind (ctx, Rel (x, k))) c,
                              fn c' =>
                                 (CAbs (x, k', c'), loc)))

              | CName _ => S.return2 cAll

              | CRecord (k, xcs) =>
                S.bind2 (mfk k,
                      fn k' =>
                         S.map2 (ListUtil.mapfold (fn (x, c) =>
                                                      S.bind2 (mfc ctx x,
                                                            fn x' =>
                                                               S.map2 (mfc ctx c,
                                                                    fn c' =>
                                                                       (x', c'))))
                                 xcs,
                              fn xcs' =>
                                 (CRecord (k', xcs'), loc)))
              | CConcat (c1, c2) =>
                S.bind2 (mfc ctx c1,
                      fn c1' =>
                         S.map2 (mfc ctx c2,
                              fn c2' =>
                                 (CConcat (c1', c2'), loc)))
              | CFold (k1, k2) =>
                S.bind2 (mfk k1,
                         fn k1' =>
                            S.map2 (mfk k2,
                                    fn k2' =>
                                       (CFold (k1', k2'), loc)))

              | CUnit => S.return2 cAll
    in
        mfc
    end

fun mapfold {kind = fk, con = fc} =
    mapfoldB {kind = fk,
              con = fn () => fc,
              bind = fn ((), _) => ()} ()

fun map {kind, con} c =
    case mapfold {kind = fn k => fn () => S.Continue (kind k, ()),
                  con = fn c => fn () => S.Continue (con c, ())} c () of
        S.Return () => raise Fail "Core_util.Con.map"
      | S.Continue (c, ()) => c

fun mapB {kind, con, bind} ctx c =
    case mapfoldB {kind = fn k => fn () => S.Continue (kind k, ()),
                   con = fn ctx => fn c => fn () => S.Continue (con ctx c, ()),
                   bind = bind} ctx c () of
        S.Continue (c, ()) => c
      | S.Return _ => raise Fail "CoreUtil.Con.mapB: Impossible"

fun fold {kind, con} s c =
    case mapfold {kind = fn k => fn s => S.Continue (k, kind (k, s)),
                  con = fn c => fn s => S.Continue (c, con (c, s))} c s of
        S.Continue (_, s) => s
      | S.Return _ => raise Fail "CoreUtil.Con.fold: Impossible"

fun exists {kind, con} k =
    case mapfold {kind = fn k => fn () =>
                                    if kind k then
                                        S.Return ()
                                    else
                                        S.Continue (k, ()),
                  con = fn c => fn () =>
                                    if con c then
                                        S.Return ()
                                    else
                                        S.Continue (c, ())} k () of
        S.Return _ => true
      | S.Continue _ => false

end

structure Exp = struct

datatype binder =
         RelC of string * kind
       | NamedC of string * int * kind * con option
       | RelE of string * con
       | NamedE of string * int * con * exp option * string

fun mapfoldB {kind = fk, con = fc, exp = fe, bind} =
    let
        val mfk = Kind.mapfold fk

        fun bind' (ctx, b) =
            let
                val b' = case b of
                             Con.Rel x => RelC x
                           | Con.Named x => NamedC x
            in
                bind (ctx, b')
            end
        val mfc = Con.mapfoldB {kind = fk, con = fc, bind = bind'}

        fun mfe ctx e acc =
            S.bindP (mfe' ctx e acc, fe ctx)

        and mfe' ctx (eAll as (e, loc)) =
            case e of
                EPrim _ => S.return2 eAll
              | ERel _ => S.return2 eAll
              | ENamed _ => S.return2 eAll
              | ECon (_, _, NONE) => S.return2 eAll
              | ECon (dk, n, SOME e) =>
                S.map2 (mfe ctx e,
                        fn e' =>
                           (ECon (dk, n, SOME e'), loc))
              | EFfi _ => S.return2 eAll
              | EFfiApp (m, x, es) =>
                S.map2 (ListUtil.mapfold (fn e => mfe ctx e) es,
                     fn es' =>
                        (EFfiApp (m, x, es'), loc))
              | EApp (e1, e2) =>
                S.bind2 (mfe ctx e1,
                      fn e1' =>
                         S.map2 (mfe ctx e2,
                              fn e2' =>
                                 (EApp (e1', e2'), loc)))
              | EAbs (x, dom, ran, e) =>
                S.bind2 (mfc ctx dom,
                      fn dom' =>
                         S.bind2 (mfc ctx ran,
                               fn ran' =>
                                  S.map2 (mfe (bind (ctx, RelE (x, dom'))) e,
                                       fn e' =>
                                          (EAbs (x, dom', ran', e'), loc))))

              | ECApp (e, c) =>
                S.bind2 (mfe ctx e,
                      fn e' =>
                         S.map2 (mfc ctx c,
                              fn c' =>
                                 (ECApp (e', c'), loc)))
              | ECAbs (x, k, e) =>
                S.bind2 (mfk k,
                      fn k' =>
                         S.map2 (mfe (bind (ctx, RelC (x, k))) e,
                              fn e' =>
                                 (ECAbs (x, k', e'), loc)))

              | ERecord xes =>
                S.map2 (ListUtil.mapfold (fn (x, e, t) =>
                                             S.bind2 (mfc ctx x,
                                                   fn x' =>
                                                      S.bind2 (mfe ctx e,
                                                            fn e' =>
                                                               S.map2 (mfc ctx t,
                                                                    fn t' =>
                                                                       (x', e', t')))))
                                         xes,
                     fn xes' =>
                        (ERecord xes', loc))
              | EField (e, c, {field, rest}) =>
                S.bind2 (mfe ctx e,
                      fn e' =>
                         S.bind2 (mfc ctx c,
                              fn c' =>
                                 S.bind2 (mfc ctx field,
                                          fn field' =>
                                             S.map2 (mfc ctx rest,
                                                  fn rest' =>
                                                     (EField (e', c', {field = field', rest = rest'}), loc)))))
              | ECut (e, c, {field, rest}) =>
                S.bind2 (mfe ctx e,
                      fn e' =>
                         S.bind2 (mfc ctx c,
                              fn c' =>
                                 S.bind2 (mfc ctx field,
                                          fn field' =>
                                             S.map2 (mfc ctx rest,
                                                  fn rest' =>
                                                     (ECut (e', c', {field = field', rest = rest'}), loc)))))
              | EFold k =>
                S.map2 (mfk k,
                         fn k' =>
                            (EFold k', loc))

              | ECase (e, pes, {disc, result}) =>
                S.bind2 (mfe ctx e,
                         fn e' =>
                            S.bind2 (ListUtil.mapfold (fn (p, e) =>
                                                         S.map2 (mfe ctx e,
                                                              fn e' => (p, e'))) pes,
                                    fn pes' =>
                                       S.bind2 (mfc ctx disc,
                                                fn disc' =>
                                                   S.map2 (mfc ctx result,
                                                        fn result' =>
                                                           (ECase (e', pes', {disc = disc', result = result'}), loc)))))

              | EWrite e =>
                S.map2 (mfe ctx e,
                     fn e' =>
                        (EWrite e', loc))

              | EClosure (n, es) =>
                S.map2 (ListUtil.mapfold (mfe ctx) es,
                     fn es' =>
                        (EClosure (n, es'), loc))
    in
        mfe
    end

fun mapfold {kind = fk, con = fc, exp = fe} =
    mapfoldB {kind = fk,
              con = fn () => fc,
              exp = fn () => fe,
              bind = fn ((), _) => ()} ()

fun mapB {kind, con, exp, bind} ctx e =
    case mapfoldB {kind = fn k => fn () => S.Continue (kind k, ()),
                   con = fn ctx => fn c => fn () => S.Continue (con ctx c, ()),
                   exp = fn ctx => fn e => fn () => S.Continue (exp ctx e, ()),
                   bind = bind} ctx e () of
        S.Continue (e, ()) => e
      | S.Return _ => raise Fail "CoreUtil.Exp.mapB: Impossible"

fun map {kind, con, exp} e =
    case mapfold {kind = fn k => fn () => S.Continue (kind k, ()),
                  con = fn c => fn () => S.Continue (con c, ()),
                  exp = fn e => fn () => S.Continue (exp e, ())} e () of
        S.Return () => raise Fail "Core_util.Exp.map"
      | S.Continue (e, ()) => e

fun fold {kind, con, exp} s e =
    case mapfold {kind = fn k => fn s => S.Continue (k, kind (k, s)),
                  con = fn c => fn s => S.Continue (c, con (c, s)),
                  exp = fn e => fn s => S.Continue (e, exp (e, s))} e s of
        S.Continue (_, s) => s
      | S.Return _ => raise Fail "CoreUtil.Exp.fold: Impossible"

fun exists {kind, con, exp} k =
    case mapfold {kind = fn k => fn () =>
                                    if kind k then
                                        S.Return ()
                                    else
                                        S.Continue (k, ()),
                  con = fn c => fn () =>
                                    if con c then
                                        S.Return ()
                                    else
                                        S.Continue (c, ()),
                  exp = fn e => fn () =>
                                    if exp e then
                                        S.Return ()
                                    else
                                        S.Continue (e, ())} k () of
        S.Return _ => true
      | S.Continue _ => false

end

structure Decl = struct

datatype binder = datatype Exp.binder

fun mapfoldB {kind = fk, con = fc, exp = fe, decl = fd, bind} =
    let
        val mfk = Kind.mapfold fk

        fun bind' (ctx, b) =
            let
                val b' = case b of
                             Con.Rel x => RelC x
                           | Con.Named x => NamedC x
            in
                bind (ctx, b')
            end
        val mfc = Con.mapfoldB {kind = fk, con = fc, bind = bind'}

        val mfe = Exp.mapfoldB {kind = fk, con = fc, exp = fe, bind = bind}

        fun mfd ctx d acc =
            S.bindP (mfd' ctx d acc, fd ctx)

        and mfd' ctx (dAll as (d, loc)) =
            case d of
                DCon (x, n, k, c) =>
                S.bind2 (mfk k,
                      fn k' =>
                         S.map2 (mfc ctx c,
                              fn c' =>
                                 (DCon (x, n, k', c'), loc)))
              | DDatatype (x, n, xncs) =>
                S.map2 (ListUtil.mapfold (fn (x, n, c) =>
                                             case c of
                                                 NONE => S.return2 (x, n, c)
                                               | SOME c =>
                                                 S.map2 (mfc ctx c,
                                                      fn c' => (x, n, SOME c'))) xncs,
                        fn xncs' =>
                           (DDatatype (x, n, xncs'), loc))
              | DVal vi =>
                S.map2 (mfvi ctx vi,
                     fn vi' =>
                        (DVal vi', loc))
              | DValRec vis =>
                let
                    val ctx = foldl (fn ((x, n, t, e, s), ctx) => bind (ctx, NamedE (x, n, t, NONE, s)))
                                    ctx vis
                in
                    S.map2 (ListUtil.mapfold (mfvi ctx) vis,
                         fn vis' =>
                            (DValRec vis', loc))
                end
              | DExport _ => S.return2 dAll

        and mfvi ctx (x, n, t, e, s) =
            S.bind2 (mfc ctx t,
                  fn t' =>
                     S.map2 (mfe ctx e,
                          fn e' =>
                             (x, n, t', e', s)))
    in
        mfd
    end    

fun mapfold {kind = fk, con = fc, exp = fe, decl = fd} =
    mapfoldB {kind = fk,
              con = fn () => fc,
              exp = fn () => fe,
              decl = fn () => fd,
              bind = fn ((), _) => ()} ()

fun fold {kind, con, exp, decl} s d =
    case mapfold {kind = fn k => fn s => S.Continue (k, kind (k, s)),
                  con = fn c => fn s => S.Continue (c, con (c, s)),
                  exp = fn e => fn s => S.Continue (e, exp (e, s)),
                  decl = fn d => fn s => S.Continue (d, decl (d, s))} d s of
        S.Continue (_, s) => s
      | S.Return _ => raise Fail "CoreUtil.Decl.fold: Impossible"

fun foldMap {kind, con, exp, decl} s d =
    case mapfold {kind = fn k => fn s => S.Continue (kind (k, s)),
                  con = fn c => fn s => S.Continue (con (c, s)),
                  exp = fn e => fn s => S.Continue (exp (e, s)),
                  decl = fn d => fn s => S.Continue (decl (d, s))} d s of
        S.Continue v => v
      | S.Return _ => raise Fail "CoreUtil.Decl.foldMap: Impossible"

end

structure File = struct

datatype binder = datatype Exp.binder

fun mapfoldB (all as {bind, ...}) =
    let
        val mfd = Decl.mapfoldB all

        fun mff ctx ds =
            case ds of
                nil => S.return2 nil
              | d :: ds' =>
                S.bind2 (mfd ctx d,
                         fn d' =>
                            let
                                val ctx' =
                                    case #1 d' of
                                        DCon (x, n, k, c) => bind (ctx, NamedC (x, n, k, SOME c))
                                      | DDatatype (x, n, xncs) =>
                                        let
                                            val ctx = bind (ctx, NamedC (x, n, (KType, #2 d'), NONE))
                                            val t = (CNamed n, #2 d')
                                        in
                                            foldl (fn ((x, n, to), ctx) =>
                                                      let
                                                          val t = case to of
                                                                      NONE => t
                                                                    | SOME t' => (TFun (t', t), #2 d')
                                                      in
                                                          bind (ctx, NamedE (x, n, t, NONE, ""))
                                                      end)
                                            ctx xncs
                                        end
                                      | DVal (x, n, t, e, s) => bind (ctx, NamedE (x, n, t, SOME e, s))
                                      | DValRec vis =>
                                        foldl (fn ((x, n, t, e, s), ctx) => bind (ctx, NamedE (x, n, t, NONE, s)))
                                        ctx vis
                                      | DExport _ => ctx
                            in
                                S.map2 (mff ctx' ds',
                                     fn ds' =>
                                        d' :: ds')
                            end)
    in
        mff
    end

fun mapfold {kind = fk, con = fc, exp = fe, decl = fd} =
    mapfoldB {kind = fk,
              con = fn () => fc,
              exp = fn () => fe,
              decl = fn () => fd,
              bind = fn ((), _) => ()} ()

fun mapB {kind, con, exp, decl, bind} ctx ds =
    case mapfoldB {kind = fn k => fn () => S.Continue (kind k, ()),
                   con = fn ctx => fn c => fn () => S.Continue (con ctx c, ()),
                   exp = fn ctx => fn e => fn () => S.Continue (exp ctx e, ()),
                   decl = fn ctx => fn d => fn () => S.Continue (decl ctx d, ()),
                   bind = bind} ctx ds () of
        S.Continue (ds, ()) => ds
      | S.Return _ => raise Fail "CoreUtil.File.mapB: Impossible"

fun fold {kind, con, exp, decl} s d =
    case mapfold {kind = fn k => fn s => S.Continue (k, kind (k, s)),
                  con = fn c => fn s => S.Continue (c, con (c, s)),
                  exp = fn e => fn s => S.Continue (e, exp (e, s)),
                  decl = fn d => fn s => S.Continue (d, decl (d, s))} d s of
        S.Continue (_, s) => s
      | S.Return _ => raise Fail "CoreUtil.File.fold: Impossible"

fun foldMap {kind, con, exp, decl} s d =
    case mapfold {kind = fn k => fn s => S.Continue (kind (k, s)),
                  con = fn c => fn s => S.Continue (con (c, s)),
                  exp = fn e => fn s => S.Continue (exp (e, s)),
                  decl = fn d => fn s => S.Continue (decl (d, s))} d s of
        S.Continue v => v
      | S.Return _ => raise Fail "CoreUtil.File.foldMap: Impossible"

val maxName = foldl (fn ((d, _) : decl, count) =>
                        case d of
                            DCon (_, n, _, _) => Int.max (n, count)
                          | DDatatype (_, n, _) => Int.max (n, count)
                          | DVal (_, n, _, _, _) => Int.max (n, count)
                          | DValRec vis => foldl (fn ((_, n, _, _, _), count) => Int.max (n, count)) count vis
                          | DExport _ => count) 0
              
end

end
