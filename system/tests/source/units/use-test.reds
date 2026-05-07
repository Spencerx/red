Red/System [
	Title:   "Red/System USE keyword test script"
	Author:  "Nenad Rakocevic"
	File: 	 %use-test.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2011-2026 Red Foundation. All rights reserved."
	License: "BSD-3 - https://github.com/red/red/blob/origin/BSD-3-License.txt"
]

#include %../../../../quick-test/quick-test.reds

~~~start-file~~~ "use"
  
  --test-- "use-1"
    use1-test: func [/local a [integer!]][
    	a: 42
    	use [b [integer!]][
    		b: 2
    		--assert b = 2
    		#if any [target = 'IA-32 target = 'ARM][
    			--assert :a - 1 = :b					;-- check that `b` stack slot is at right location.
    		]
    	]
    	--assert a = 42
    ]
    use1-test
 


~~~end-file~~~

