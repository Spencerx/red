Red/System [
	Title:   "Red memory garbage collector"
	Author:  "Nenad Rakocevic"
	File: 	 %collector.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2015-2017 Nenad Rakocevic. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
	Notes: "Implements the naive Mark&Sweep method."
]

collector: context [
	verbose: 0
	active?: no
	
	stats: declare struct! [
		cycles [integer!]
	]
	
	ext-size: 100
	ext-markers: as int-ptr! allocate ext-size * size? int-ptr!
	ext-top: ext-markers
	
	stats/cycles: 0
	
	indent: 0
	
	frames-list: context [
		list:	   as node! 0
		min-size:  1000
		fit-cache: 16									;-- nb of pointers fitting into a typical 64 bytes L1 cache
		buf-size:  min-size								;-- initial number of supported frames
		count:	   0									;-- current number of stored frames
		
		compare-cb: func [[cdecl] a [int-ptr!] b [int-ptr!] return: [integer!]][
			SIGN_COMPARE_RESULT((as int-ptr! a/value) (as int-ptr! b/value))
		]

		build: func [									;-- build an array of node frames pointers
			/local
				frm	[node-frame!]
				pos [int-ptr!]
				cnt [integer!]
		][
			if null? list [
				;-- allocation alignement not guaranteed, so L1 cache optmization is only eventual.
				list: as node! allocate buf-size * size? node!
			]
			cnt: 0
			frm: memory/n-head
			pos: list
			until [
				pos/value: as-integer frm
				pos: pos + 1
				cnt: cnt + 1
				if cnt >= buf-size [
					buf-size: buf-size * 2
					list: as node! realloc as byte-ptr! list buf-size * size? node!
					pos: list + cnt
				]
				frm: frm/next
				frm = null
			]
			if all [cnt > min-size cnt * 3 < buf-size][	;-- shrink buffer if 2/3 or more are not used
				buf-size: cnt
				list: as node! realloc as byte-ptr! list buf-size * size? node!
			]
			qsort as byte-ptr! list cnt 4 :compare-cb	;-- sort the array
			count: cnt
		]
		
		find: func [
			node	[node!]
			return: [logic!]
			/local
				frm p s e [node!]
				w	 [integer!]
				end? [logic!]
		][	
			w: nodes-per-frame * size? node! 			;-- node frame width
		
			either count <= fit-cache [					;== linear search
				p: list
				loop count [
					frm: as node! p/value + size? node-frame!
					if all [frm <= node node < as node! ((as byte-ptr! frm) + w)][return yes]
					p: p + 1
				]
			][											;== binary search for arrays bigger than 16 nodes
				s: list									;-- low pointer
				e: list + (count - 1)					;-- high pointer
				until [
					p: s + ((as-integer e - s) >> 2 + 1 / 2) ;-- points to the middle of [s,e] segment
					frm: as node! p/value + size? node-frame!
					if all [frm <= node node < as node! ((as byte-ptr! frm) + w)][return yes]
					end?: s = e							;-- gives a chance to probe the s = e segment
					either (as node! p/value) < node [s: p][e: p - 1] ;-- chooses lower or upper segment
					end?
				]
			]
			no
		]
	]
	
	nodes-list: context [								;-- nodes freeing batch handling
		list:	  as int-ptr! 0
		min-size: 20
		buf-size: min-size								;-- initial number of supported nodes
		count:	  0										;-- current number of stored nodes
		
		init: does [list: as int-ptr! allocate buf-size * size? node!]
		
		store: func [node [node!]][
			if null? node [exit]						;-- expanded series sets null node in old series
			if count = buf-size [flush]					;-- buffer full, flush it first
			count: count + 1
			list/count: as-integer node
		]
		
		flush: func [									;-- assumes frames-list buffer is built and sorted
			/local
				frm p e n [int-ptr!]
				frm-nb w [integer!]
		][
			qsort as byte-ptr! list count 4 :frames-list/compare-cb
			p: frames-list/list
			e: p + frames-list/count
			w: nodes-per-frame * size? node!			;-- node frame width
			n: list
			
			loop count [
				while [
					frm: as int-ptr! p/value + size? node-frame!
					not all [frm <= as node! n/value (as node! n/value) < as node! ((as byte-ptr! frm) + w)]
				][
					p: p + 1
					assert p <= e
				]
				free-node as node-frame! p/value as node! n/value
				n: n + 1
			]
			count: 0
		]
	]
	
	mark-stack-nodes: func [
		/local
			top	 [int-ptr!]
			stk	 [int-ptr!]
			p	 [int-ptr!]
			s	 [series!]
	][
		top: system/stack/top
		stk: stk-bottom
		
		until [
			stk: stk - 1
			p: as int-ptr! stk/value
			if all [
				(as-integer p) and 3 = 0		;-- check if it's a valid int-ptr!
				p > as int-ptr! FFFFh			;-- filter out too low values
				p < as int-ptr! FFFFF000h		;-- filter out too high values
				not all [(as byte-ptr! stack/bottom) <= p p <= (as byte-ptr! stack/top)] ;-- stack region is fixed
				frames-list/find p
				p/value <> 0
				not frames-list/find as int-ptr! p/value ;-- freed nodes can still be on the stack!
				keep p
			][
				;probe ["node pointer on stack: " p " : " as byte-ptr! p/value]
				s: as series! p/value
				if GET_UNIT(s) = 16 [mark-values s/offset s/tail]
			]
			stk = top
		]
	]
	
	keep: func [
		node	[node!]
		return: [logic!]								;-- TRUE if newly marked, FALSE if already done
		/local
			s	  [series!]
			new?  [logic!]
			flags [integer!]
	][
		s: as series! node/value
		flags: s/flags
		new?: flags and flag-gc-mark = 0
		if new? [s/flags: flags or flag-gc-mark]
		new?
	]

	unmark: func [
		node	 [node!]
		/local s [series!]
	][
		s: as series! node/value
		s/flags: s/flags and not flag-gc-mark
	]
	
	mark-context: func [
		node [node!]
		/local
			ctx  [red-context!]
			slot [red-value!]
	][
		if keep node [
			ctx: TO_CTX(node)							;-- [context! function!|object!]
			slot: as red-value! ctx
			_hashtable/mark ctx/symbols
			unless ON_STACK?(ctx) [mark-block-node ctx/values]
			mark-values slot + 1 slot + 2				;-- mark the back-reference value (2nd value)
		]
	]

	mark-values: func [
		value [red-value!]
		tail  [red-value!]
		/local
			series	[red-series!]
			obj		[red-object!]
			hash	[red-hash!]
			word	[red-word!]
			path	[red-path!]
			fun		[red-function!]
			routine [red-routine!]
			native	[red-native!]
			ctx		[red-context!]
			image	[red-image!]
			len		[integer!]
			type	[integer!]
	][
		#if debug? = yes [if verbose > 1 [len: -1 indent: indent + 1]]
		
		while [value < tail][
			#if debug? = yes [if verbose > 1 [
				print "^/"
				loop indent * 4 [print "  "]
				print [TYPE_OF(value) ": "]
			]]
			
			switch TYPE_OF(value) [
				TYPE_WORD 
				TYPE_GET_WORD
				TYPE_SET_WORD 
				TYPE_LIT_WORD
				TYPE_REFINEMENT [
					word: as red-word! value
					if word/ctx <> null [
						#if debug? = yes [if verbose > 1 [print-symbol word]]
						either word/symbol = words/self [
							mark-block-node word/ctx
						][
							mark-context word/ctx
						]
					]
				]
				TYPE_BLOCK
				TYPE_PAREN
				TYPE_ANY_PATH [
					series: as red-series! value
					if series/node <> null [			;-- can happen in routine
						#if debug? = yes [if verbose > 1 [print ["len: " block/rs-length? as red-block! series]]]
						mark-block as red-block! value
					]
				]
				TYPE_SYMBOL [
					series: as red-series! value
					keep as node! series/extra
					if series/node <> null [keep series/node]
				]
				TYPE_ANY_STRING [
					#if debug? = yes [if verbose > 1 [print as-c-string string/rs-head as red-string! value]]
					series: as red-series! value
					keep series/node
					if series/extra <> 0 [keep as node! series/extra]
				]
				TYPE_BINARY
				TYPE_VECTOR
				TYPE_BITSET [
					;probe ["bitset, type: " TYPE_OF(value)]
					series: as red-series! value
					keep series/node
				]
				TYPE_ERROR
				TYPE_PORT
				TYPE_OBJECT [
					#if debug? = yes [if verbose > 1 [print "object"]]
					obj: as red-object! value
					mark-context obj/ctx
					if obj/on-set <> null [keep obj/on-set]
				]
				TYPE_CONTEXT [
					#if debug? = yes [if verbose > 1 [print "context"]]
					ctx: as red-context! value
					;keep ctx/self
					_hashtable/mark ctx/symbols
					unless ON_STACK?(ctx) [mark-block-node ctx/values]
				]
				TYPE_HASH
				TYPE_MAP [
					#if debug? = yes [if verbose > 1 [print "hash/map"]]
					hash: as red-hash! value
					mark-block-node hash/node
					_hashtable/mark hash/table			;@@ check if previously marked
				]
				TYPE_FUNCTION
				TYPE_ROUTINE [
					#if debug? = yes [if verbose > 1 [print "function"]]
					fun: as red-function! value
					mark-context fun/ctx
					mark-block-node fun/spec
					mark-block-node fun/more
				]
				TYPE_ACTION
				TYPE_NATIVE
				TYPE_OP [
					native: as red-native! value
					mark-block-node native/spec
					mark-block-node native/more
					if TYPE_OF(native) = TYPE_OP [
						type: GET_OP_SUBTYPE(native)
						if any [type = TYPE_FUNCTION type = TYPE_ROUTINE][
							mark-context as node! native/code
						]
					]
				]
				#if any [OS = 'macOS OS = 'Linux OS = 'Windows][
				TYPE_IMAGE [
					image: as red-image! value
					#if draw-engine <> 'GDI+ [if image/node <> null [keep image/node]]
				]]
				default [0]
			]
			value: value + 1
		]
		#if debug? = yes [if verbose > 1 [indent: indent - 1]]
	]
	
	mark-block-node: func [
		node [node!]
		/local
			s [series!]
	][
		if keep node [
			s: as series! node/value
			mark-values s/offset s/tail
		]
	]
	
	mark-block: func [
		blk [red-block!]
		/local
			s [series!]
	][
		if keep blk/node [
			s: GET_BUFFER(blk)
			mark-values s/offset s/tail
		]
	]
	
	do-mark-sweep: func [
		/local
			s		[series!]
			p		[int-ptr!]
			obj		[red-object!]
			w		[red-word!]
		#if debug? = yes [
			file	[c-string!]
			saved	[integer!]
			buf		[c-string!]
			tm tm1	[float!]
		]
			cb		[function! []]
	][
		#if debug? = yes [if verbose > 1 [
			#if OS = 'Windows [platform/dos-console?: no]
			file: "                      "
			sprintf [file "live-values-%d.log" stats/cycles]
			saved: stdout
			stdout: simple-io/open-file file simple-io/RIO_APPEND no
		]]

		#if debug? = yes [
			if verbose > 2 [stack-trace]
			buf: "                                                               "
			tm: platform/get-time yes yes
			print [
				"root: " block/rs-length? root "/" ***-root-size
				", runs: " stats/cycles
				", mem: " 	memory-info null 1
			]
			if verbose > 1 [probe "^/marking..."]
		]

		mark-block root
		#if debug? = yes [if verbose > 1 [probe "marking symbol table"]]
		_hashtable/mark symbol/table					;-- will mark symbols
		#if debug? = yes [if verbose > 1 [probe "marking ownership table"]]
		_hashtable/mark ownership/table

		#if debug? = yes [if verbose > 1 [probe "marking stack"]]
		keep arg-stk/node
		keep call-stk/node
		mark-values stack/bottom stack/top
		
		#if debug? = yes [if verbose > 1 [probe "marking globals"]]
		if interpreter/near/node <> null [keep interpreter/near/node]
		lexer/mark-buffers
		
		#if debug? = yes [if verbose > 1 [probe "marking globals from optional modules"]]
		p: ext-markers
		while [p < ext-top][
			if p/value <> 0 [							;-- check if not unregistered
				cb: as function! [] p/value
				cb
			]
			p: p + 1
		]
		
		#if debug? = yes [if verbose > 1 [probe "marking nodes on native stack"]]
		frames-list/build
		mark-stack-nodes

		#if debug? = yes [tm1: (platform/get-time yes yes) - tm]	;-- marking time

		#if debug? = yes [if verbose > 1 [probe "sweeping..."]]
		_hashtable/sweep ownership/table
		collect-series-frames COLLECTOR_RELEASE
		collect-big-frames
		nodes-list/flush
		collect-node-frames
		;extract-stack-refs no
	
		;-- unmark fixed series
		unmark root/node
		unmark arg-stk/node
		unmark call-stk/node
		
		stats/cycles: stats/cycles + 1
		;probe "done!"

		#if debug? = yes [
			tm: (platform/get-time yes yes) - tm - tm1
			sprintf [buf ", mark: %.1fms, sweep: %.1fms" tm1 * 1000.0 tm * 1000.0]
			probe [" => " memory-info null 1 buf]
			if verbose > 1 [
				simple-io/close-file stdout
				stdout: saved
				#if OS = 'Windows [platform/dos-console?: yes]
			]
		]
	]
	
	do-cycle: does [
		unless active? [exit]
		do-mark-sweep
	]
	
	register: func [cb [int-ptr!]][
		assert (as-integer ext-top - ext-markers) >> 2 < ext-size
		ext-top/value: as-integer cb
		ext-top: ext-top + 1
	]
	
	unregister: func [cb [int-ptr!] /local p [int-ptr!]][
		p: ext-markers
		while [p < ext-top][
			if p/value = as-integer cb [p/value: 0 exit]
			p: p + 1
		]
	]
	
]