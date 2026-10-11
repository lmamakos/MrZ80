# Custom Z-80 instruction for FORTH NEXT

**Session ID:** ses_152556449ffeRGeYAoH4i1cwi4
**Created:** 6/9/2026, 6:34:59 PM
**Updated:** 6/9/2026, 6:38:41 PM

---

## User

Consider the Components/Z80 directory which contains a VHDL implementation of a Z-80 CPU, used as part of an FPGA reimplementation of a Z-80 CP/M system running the RomWBW open source code distribution.  Within RomWBW is a FORTH implementation for the Z-80 called CamelFORTH.   I would like to implement a custom instruction in the Z-80 HDL for the FORTH "NEXT" primitive which is used in the FORTH implementation.

This FORTH implementation uses the Z-80 registers like this:

```
; Direct-Threaded Forth model for Zilog Z80
; 16 bit cell, 8 bit char, 8 bit (byte) adrs unit
;    Z80 BC = Forth TOS (top Param Stack item)
;        HL =       W    working register
;        DE =       IP   Interpreter Pointer
;        SP =       PSP  Param Stack Pointer
;        IX =       RSP  Return Stack Pointer
;        IY =       UP   User area Pointer
;    A, alternate register set = temporaries 
```

The existing `NEXT` implementation is done as a Macro at the end of each FORTH word implementation.  The goal is to reduce the code size by replacing each instance with a single Z-80 instruction and also speed up the FORTH implementation.   At present, the `NEXT` macro looks like this:

```
; The NEXT macro (7 bytes) assembles the 'next'
; code in-line in every Z80 CamelForth CODE word.
next    MACRO
        ex de,hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ex de,hl
        jp (hl)
        ENDM 
```

Implement a new instruction in the Z-80's "Misc. Instructions" introduced by the`0xED` prefix, and show me the proposed changes.

---

## Assistant (Plan · Claude Opus 4.8 · 3.6s)

I'll explore the Z-80 VHDL implementation to understand how instructions are decoded and implemented, particularly the `0xED` prefixed instructions, so I can plan how to add the FORTH `NEXT` primitive.

**Tool: bash**

**Input:**
```json
{
  "description": "List Z80 component directory",
  "command": "ls -la Components/Z80/"
}
```

**Output:**
```
total 81
drwxr-xr-x  2 louie louie     9 Jun  7 03:47 .
drwxr-xr-x 12 louie louie    12 May 30 21:59 ..
-rw-r--r--  1 louie louie 10637 May  6 23:23 T80_ALU.vhd
-rw-r--r--  1 louie louie 50680 May  6 23:23 T80_MCode.vhd
-rw-r--r--  1 louie louie  6880 Jun  7 03:42 T80_Pack.vhd
-rw-r--r--  1 louie louie  3719 Jun  7 03:39 T80_Reg.vhd
-rw-r--r--  1 louie louie  4397 May  6 23:23 T80_RegX.vhd
-rw-r--r--  1 louie louie  5449 Jun  7 03:47 T80s.vhd
-rw-r--r--  1 louie louie 29620 Jun  7 03:41 T80.vhd

```

---

## Assistant (Plan · Claude Opus 4.8 · 2.6s)

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd"
}
```

**Output:**
```
<path>/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd</path>
<type>file</type>
<content>
1: --
2: -- Z80 compatible microprocessor core
3: --
4: -- Version : 0242
5: --
6: -- Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
7: --
8: -- All rights reserved
9: --
10: -- Redistribution and use in source and synthezised forms, with or without
11: -- modification, are permitted provided that the following conditions are met:
12: --
13: -- Redistributions of source code must retain the above copyright notice,
14: -- this list of conditions and the following disclaimer.
15: --
16: -- Redistributions in synthesized form must reproduce the above copyright
17: -- notice, this list of conditions and the following disclaimer in the
18: -- documentation and/or other materials provided with the distribution.
19: --
20: -- Neither the name of the author nor the names of other contributors may
21: -- be used to endorse or promote products derived from this software without
22: -- specific prior written permission.
23: --
24: -- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
25: -- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
26: -- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
27: -- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
28: -- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
29: -- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
30: -- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
31: -- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
32: -- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
33: -- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
34: -- POSSIBILITY OF SUCH DAMAGE.
35: --
36: -- Please report bugs to the author, but before you do so, please
37: -- make sure that this is not a derivative work and that
38: -- you have the latest version of this file.
39: --
40: -- The latest version of this file can be found at:
41: --	http://www.opencores.org/cvsweb.shtml/t80/
42: --
43: -- Limitations :
44: --
45: -- File history :
46: --
47: --	0208 : First complete release
48: --
49: --	0211 : Fixed IM 1
50: --
51: --	0214 : Fixed mostly flags, only the block instructions now fail the zex regression test
52: --
53: --	0235 : Added IM 2 fix by Mike Johnson
54: --
55: --	0238 : Added NoRead signal
56: --
57: --	0238b: Fixed instruction timing for POP and DJNZ
58: --
59: --	0240 : Added (IX/IY+d) states, removed op-codes from mode 2 and added all remaining mode 3 op-codes
60: --
61: --	0242 : Fixed I/O instruction timing, cleanup
62: --
63: 
64: library IEEE;
65: use IEEE.std_logic_1164.all;
66: use IEEE.numeric_std.all;
67: 
68: entity T80_MCode is
69: 	generic(
70: 		Mode : integer := 0;
71: 		Flag_C : integer := 0;
72: 		Flag_N : integer := 1;
73: 		Flag_P : integer := 2;
74: 		Flag_X : integer := 3;
75: 		Flag_H : integer := 4;
76: 		Flag_Y : integer := 5;
77: 		Flag_Z : integer := 6;
78: 		Flag_S : integer := 7
79: 	);
80: 	port(
81: 		IR				: in std_logic_vector(7 downto 0);
82: 		ISet			: in std_logic_vector(1 downto 0);
83: 		MCycle			: in std_logic_vector(2 downto 0);
84: 		F				: in std_logic_vector(7 downto 0);
85: 		NMICycle		: in std_logic;
86: 		IntCycle		: in std_logic;
87: 		MCycles			: out std_logic_vector(2 downto 0);
88: 		TStates			: out std_logic_vector(2 downto 0);
89: 		Prefix			: out std_logic_vector(1 downto 0); -- None,BC,ED,DD/FD
90: 		Inc_PC			: out std_logic;
91: 		Inc_WZ			: out std_logic;
92: 		IncDec_16		: out std_logic_vector(3 downto 0); -- BC,DE,HL,SP   0 is inc
93: 		Read_To_Reg		: out std_logic;
94: 		Read_To_Acc		: out std_logic;
95: 		Set_BusA_To	: out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI/DB,A,SP(L),SP(M),0,F
96: 		Set_BusB_To	: out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI,A,SP(L),SP(M),1,F,PC(L),PC(M),0
97: 		ALU_Op			: out std_logic_vector(3 downto 0);
98: 			-- ADD, ADC, SUB, SBC, AND, XOR, OR, CP, ROT, BIT, SET, RES, DAA, RLD, RRD, None
99: 		Save_ALU		: out std_logic;
100: 		PreserveC		: out std_logic;
101: 		Arith16			: out std_logic;
102: 		Set_Addr_To		: out std_logic_vector(2 downto 0); -- aNone,aXY,aIOA,aSP,aBC,aDE,aZI
103: 		IORQ			: out std_logic;
104: 		Jump			: out std_logic;
105: 		JumpE			: out std_logic;
106: 		JumpXY			: out std_logic;
107: 		Call			: out std_logic;
108: 		RstP			: out std_logic;
109: 		LDZ				: out std_logic;
110: 		LDW				: out std_logic;
111: 		LDSPHL			: out std_logic;
112: 		Special_LD		: out std_logic_vector(2 downto 0); -- A,I;A,R;I,A;R,A;None
113: 		ExchangeDH		: out std_logic;
114: 		ExchangeRp		: out std_logic;
115: 		ExchangeAF		: out std_logic;
116: 		ExchangeRS		: out std_logic;
117: 		I_DJNZ			: out std_logic;
118: 		I_CPL			: out std_logic;
119: 		I_CCF			: out std_logic;
120: 		I_SCF			: out std_logic;
121: 		I_RETN			: out std_logic;
122: 		I_BT			: out std_logic;
123: 		I_BC			: out std_logic;
124: 		I_BTR			: out std_logic;
125: 		I_RLD			: out std_logic;
126: 		I_RRD			: out std_logic;
127: 		I_INRC			: out std_logic;
128: 		SetDI			: out std_logic;
129: 		SetEI			: out std_logic;
130: 		IMode			: out std_logic_vector(1 downto 0);
131: 		Halt			: out std_logic;
132: 		NoRead			: out std_logic;
133: 		Write			: out std_logic
134: 	);
135: end T80_MCode;
136: 
137: architecture rtl of T80_MCode is
138: 
139: 	constant aNone	: std_logic_vector(2 downto 0) := "111";
140: 	constant aBC	: std_logic_vector(2 downto 0) := "000";
141: 	constant aDE	: std_logic_vector(2 downto 0) := "001";
142: 	constant aXY	: std_logic_vector(2 downto 0) := "010";
143: 	constant aIOA	: std_logic_vector(2 downto 0) := "100";
144: 	constant aSP	: std_logic_vector(2 downto 0) := "101";
145: 	constant aZI	: std_logic_vector(2 downto 0) := "110";
146: --	constant aNone	: std_logic_vector(2 downto 0) := "000";
147: --	constant aXY	: std_logic_vector(2 downto 0) := "001";
148: --	constant aIOA	: std_logic_vector(2 downto 0) := "010";
149: --	constant aSP	: std_logic_vector(2 downto 0) := "011";
150: --	constant aBC	: std_logic_vector(2 downto 0) := "100";
151: --	constant aDE	: std_logic_vector(2 downto 0) := "101";
152: --	constant aZI	: std_logic_vector(2 downto 0) := "110";
153: 
154: 	function is_cc_true(
155: 		F : std_logic_vector(7 downto 0);
156: 		cc : bit_vector(2 downto 0)
157: 		) return boolean is
158: 	begin
159: 		if Mode = 3 then
160: 			case cc is
161: 			when "000" => return F(7) = '0'; -- NZ
162: 			when "001" => return F(7) = '1'; -- Z
163: 			when "010" => return F(4) = '0'; -- NC
164: 			when "011" => return F(4) = '1'; -- C
165: 			when "100" => return false;
166: 			when "101" => return false;
167: 			when "110" => return false;
168: 			when "111" => return false;
169: 			end case;
170: 		else
171: 			case cc is
172: 			when "000" => return F(6) = '0'; -- NZ
173: 			when "001" => return F(6) = '1'; -- Z
174: 			when "010" => return F(0) = '0'; -- NC
175: 			when "011" => return F(0) = '1'; -- C
176: 			when "100" => return F(2) = '0'; -- PO
177: 			when "101" => return F(2) = '1'; -- PE
178: 			when "110" => return F(7) = '0'; -- P
179: 			when "111" => return F(7) = '1'; -- M
180: 			end case;
181: 		end if;
182: 	end;
183: 
184: begin
185: 
186: 	process (IR, ISet, MCycle, F, NMICycle, IntCycle)
187: 		variable DDD : std_logic_vector(2 downto 0);
188: 		variable SSS : std_logic_vector(2 downto 0);
189: 		variable DPair : std_logic_vector(1 downto 0);
190: 		variable IRB : bit_vector(7 downto 0);
191: 	begin
192: 		DDD := IR(5 downto 3);
193: 		SSS := IR(2 downto 0);
194: 		DPair := IR(5 downto 4);
195: 		IRB := to_bitvector(IR);
196: 
197: 		MCycles <= "001";
198: 		if MCycle = "001" then
199: 			TStates <= "100";
200: 		else
201: 			TStates <= "011";
202: 		end if;
203: 		Prefix <= "00";
204: 		Inc_PC <= '0';
205: 		Inc_WZ <= '0';
206: 		IncDec_16 <= "0000";
207: 		Read_To_Acc <= '0';
208: 		Read_To_Reg <= '0';
209: 		Set_BusB_To <= "0000";
210: 		Set_BusA_To <= "0000";
211: 		ALU_Op <= "0" & IR(5 downto 3);
212: 		Save_ALU <= '0';
213: 		PreserveC <= '0';
214: 		Arith16 <= '0';
215: 		IORQ <= '0';
216: 		Set_Addr_To <= aNone;
217: 		Jump <= '0';
218: 		JumpE <= '0';
219: 		JumpXY <= '0';
220: 		Call <= '0';
221: 		RstP <= '0';
222: 		LDZ <= '0';
223: 		LDW <= '0';
224: 		LDSPHL <= '0';
225: 		Special_LD <= "000";
226: 		ExchangeDH <= '0';
227: 		ExchangeRp <= '0';
228: 		ExchangeAF <= '0';
229: 		ExchangeRS <= '0';
230: 		I_DJNZ <= '0';
231: 		I_CPL <= '0';
232: 		I_CCF <= '0';
233: 		I_SCF <= '0';
234: 		I_RETN <= '0';
235: 		I_BT <= '0';
236: 		I_BC <= '0';
237: 		I_BTR <= '0';
238: 		I_RLD <= '0';
239: 		I_RRD <= '0';
240: 		I_INRC <= '0';
241: 		SetDI <= '0';
242: 		SetEI <= '0';
243: 		IMode <= "11";
244: 		Halt <= '0';
245: 		NoRead <= '0';
246: 		Write <= '0';
247: 
248: 		case ISet is
249: 		when "00" =>
250: 
251: ------------------------------------------------------------------------------
252: --
253: --	Unprefixed instructions
254: --
255: ------------------------------------------------------------------------------
256: 
257: 		case IRB is
258: -- 8 BIT LOAD GROUP
259: 		when "01000000"|"01000001"|"01000010"|"01000011"|"01000100"|"01000101"|"01000111"
260: 			|"01001000"|"01001001"|"01001010"|"01001011"|"01001100"|"01001101"|"01001111"
261: 			|"01010000"|"01010001"|"01010010"|"01010011"|"01010100"|"01010101"|"01010111"
262: 			|"01011000"|"01011001"|"01011010"|"01011011"|"01011100"|"01011101"|"01011111"
263: 			|"01100000"|"01100001"|"01100010"|"01100011"|"01100100"|"01100101"|"01100111"
264: 			|"01101000"|"01101001"|"01101010"|"01101011"|"01101100"|"01101101"|"01101111"
265: 			|"01111000"|"01111001"|"01111010"|"01111011"|"01111100"|"01111101"|"01111111" =>
266: 			-- LD r,r'
267: 			Set_BusB_To(2 downto 0) <= SSS;
268: 			ExchangeRp <= '1';
269: 			Set_BusA_To(2 downto 0) <= DDD;
270: 			Read_To_Reg <= '1';
271: 		when "00000110"|"00001110"|"00010110"|"00011110"|"00100110"|"00101110"|"00111110" =>
272: 			-- LD r,n
273: 			MCycles <= "010";
274: 			case to_integer(unsigned(MCycle)) is
275: 			when 2 =>
276: 				Inc_PC <= '1';
277: 				Set_BusA_To(2 downto 0) <= DDD;
278: 				Read_To_Reg <= '1';
279: 			when others => null;
280: 			end case;
281: 		when "01000110"|"01001110"|"01010110"|"01011110"|"01100110"|"01101110"|"01111110" =>
282: 			-- LD r,(HL)
283: 			MCycles <= "010";
284: 			case to_integer(unsigned(MCycle)) is
285: 			when 1 =>
286: 				Set_Addr_To <= aXY;
287: 			when 2 =>
288: 				Set_BusA_To(2 downto 0) <= DDD;
289: 				Read_To_Reg <= '1';
290: 			when others => null;
291: 			end case;
292: 		when "01110000"|"01110001"|"01110010"|"01110011"|"01110100"|"01110101"|"01110111" =>
293: 			-- LD (HL),r
294: 			MCycles <= "010";
295: 			case to_integer(unsigned(MCycle)) is
296: 			when 1 =>
297: 				Set_Addr_To <= aXY;
298: 				Set_BusB_To(2 downto 0) <= SSS;
299: 				Set_BusB_To(3) <= '0';
300: 			when 2 =>
301: 				Write <= '1';
302: 			when others => null;
303: 			end case;
304: 		when "00110110" =>
305: 			-- LD (HL),n
306: 			MCycles <= "011";
307: 			case to_integer(unsigned(MCycle)) is
308: 			when 2 =>
309: 				Inc_PC <= '1';
310: 				Set_Addr_To <= aXY;
311: 				Set_BusB_To(2 downto 0) <= SSS;
312: 				Set_BusB_To(3) <= '0';
313: 			when 3 =>
314: 				Write <= '1';
315: 			when others => null;
316: 			end case;
317: 		when "00001010" =>
318: 			-- LD A,(BC)
319: 			MCycles <= "010";
320: 			case to_integer(unsigned(MCycle)) is
321: 			when 1 =>
322: 				Set_Addr_To <= aBC;
323: 			when 2 =>
324: 				Read_To_Acc <= '1';
325: 			when others => null;
326: 			end case;
327: 		when "00011010" =>
328: 			-- LD A,(DE)
329: 			MCycles <= "010";
330: 			case to_integer(unsigned(MCycle)) is
331: 			when 1 =>
332: 				Set_Addr_To <= aDE;
333: 			when 2 =>
334: 				Read_To_Acc <= '1';
335: 			when others => null;
336: 			end case;
337: 		when "00111010" =>
338: 			if Mode = 3 then
339: 				-- LDD A,(HL)
340: 				MCycles <= "010";
341: 				case to_integer(unsigned(MCycle)) is
342: 				when 1 =>
343: 					Set_Addr_To <= aXY;
344: 				when 2 =>
345: 					Read_To_Acc <= '1';
346: 					IncDec_16 <= "1110";
347: 				when others => null;
348: 				end case;
349: 			else
350: 				-- LD A,(nn)
351: 				MCycles <= "100";
352: 				case to_integer(unsigned(MCycle)) is
353: 				when 2 =>
354: 					Inc_PC <= '1';
355: 					LDZ <= '1';
356: 				when 3 =>
357: 					Set_Addr_To <= aZI;
358: 					Inc_PC <= '1';
359: 				when 4 =>
360: 					Read_To_Acc <= '1';
361: 				when others => null;
362: 				end case;
363: 			end if;
364: 		when "00000010" =>
365: 			-- LD (BC),A
366: 			MCycles <= "010";
367: 			case to_integer(unsigned(MCycle)) is
368: 			when 1 =>
369: 				Set_Addr_To <= aBC;
370: 				Set_BusB_To <= "0111";
371: 			when 2 =>
372: 				Write <= '1';
373: 			when others => null;
374: 			end case;
375: 		when "00010010" =>
376: 			-- LD (DE),A
377: 			MCycles <= "010";
378: 			case to_integer(unsigned(MCycle)) is
379: 			when 1 =>
380: 				Set_Addr_To <= aDE;
381: 				Set_BusB_To <= "0111";
382: 			when 2 =>
383: 				Write <= '1';
384: 			when others => null;
385: 			end case;
386: 		when "00110010" =>
387: 			if Mode = 3 then
388: 				-- LDD (HL),A
389: 				MCycles <= "010";
390: 				case to_integer(unsigned(MCycle)) is
391: 				when 1 =>
392: 					Set_Addr_To <= aXY;
393: 					Set_BusB_To <= "0111";
394: 				when 2 =>
395: 					Write <= '1';
396: 					IncDec_16 <= "1110";
397: 				when others => null;
398: 				end case;
399: 			else
400: 				-- LD (nn),A
401: 				MCycles <= "100";
402: 				case to_integer(unsigned(MCycle)) is
403: 				when 2 =>
404: 					Inc_PC <= '1';
405: 					LDZ <= '1';
406: 				when 3 =>
407: 					Set_Addr_To <= aZI;
408: 					Inc_PC <= '1';
409: 					Set_BusB_To <= "0111";
410: 				when 4 =>
411: 					Write <= '1';
412: 				when others => null;
413: 				end case;
414: 			end if;
415: 
416: -- 16 BIT LOAD GROUP
417: 		when "00000001"|"00010001"|"00100001"|"00110001" =>
418: 			-- LD dd,nn
419: 			MCycles <= "011";
420: 			case to_integer(unsigned(MCycle)) is
421: 			when 2 =>
422: 				Inc_PC <= '1';
423: 				Read_To_Reg <= '1';
424: 				if DPAIR = "11" then
425: 					Set_BusA_To(3 downto 0) <= "1000";
426: 				else
427: 					Set_BusA_To(2 downto 1) <= DPAIR;
428: 					Set_BusA_To(0) <= '1';
429: 				end if;
430: 			when 3 =>
431: 				Inc_PC <= '1';
432: 				Read_To_Reg <= '1';
433: 				if DPAIR = "11" then
434: 					Set_BusA_To(3 downto 0) <= "1001";
435: 				else
436: 					Set_BusA_To(2 downto 1) <= DPAIR;
437: 					Set_BusA_To(0) <= '0';
438: 				end if;
439: 			when others => null;
440: 			end case;
441: 		when "00101010" =>
442: 			if Mode = 3 then
443: 				-- LDI A,(HL)
444: 				MCycles <= "010";
445: 				case to_integer(unsigned(MCycle)) is
446: 				when 1 =>
447: 					Set_Addr_To <= aXY;
448: 				when 2 =>
449: 					Read_To_Acc <= '1';
450: 					IncDec_16 <= "0110";
451: 				when others => null;
452: 				end case;
453: 			else
454: 				-- LD HL,(nn)
455: 				MCycles <= "101";
456: 				case to_integer(unsigned(MCycle)) is
457: 				when 2 =>
458: 					Inc_PC <= '1';
459: 					LDZ <= '1';
460: 				when 3 =>
461: 					Set_Addr_To <= aZI;
462: 					Inc_PC <= '1';
463: 					LDW <= '1';
464: 				when 4 =>
465: 					Set_BusA_To(2 downto 0) <= "101"; -- L
466: 					Read_To_Reg <= '1';
467: 					Inc_WZ <= '1';
468: 					Set_Addr_To <= aZI;
469: 				when 5 =>
470: 					Set_BusA_To(2 downto 0) <= "100"; -- H
471: 					Read_To_Reg <= '1';
472: 				when others => null;
473: 				end case;
474: 			end if;
475: 		when "00100010" =>
476: 			if Mode = 3 then
477: 				-- LDI (HL),A
478: 				MCycles <= "010";
479: 				case to_integer(unsigned(MCycle)) is
480: 				when 1 =>
481: 					Set_Addr_To <= aXY;
482: 					Set_BusB_To <= "0111";
483: 				when 2 =>
484: 					Write <= '1';
485: 					IncDec_16 <= "0110";
486: 				when others => null;
487: 				end case;
488: 			else
489: 				-- LD (nn),HL
490: 				MCycles <= "101";
491: 				case to_integer(unsigned(MCycle)) is
492: 				when 2 =>
493: 					Inc_PC <= '1';
494: 					LDZ <= '1';
495: 				when 3 =>
496: 					Set_Addr_To <= aZI;
497: 					Inc_PC <= '1';
498: 					LDW <= '1';
499: 					Set_BusB_To <= "0101"; -- L
500: 				when 4 =>
501: 					Inc_WZ <= '1';
502: 					Set_Addr_To <= aZI;
503: 					Write <= '1';
504: 					Set_BusB_To <= "0100"; -- H
505: 				when 5 =>
506: 					Write <= '1';
507: 				when others => null;
508: 				end case;
509: 			end if;
510: 		when "11111001" =>
511: 			-- LD SP,HL
512: 			TStates <= "110";
513: 			LDSPHL <= '1';
514: 		when "11000101"|"11010101"|"11100101"|"11110101" =>
515: 			-- PUSH qq
516: 			MCycles <= "011";
517: 			case to_integer(unsigned(MCycle)) is
518: 			when 1 =>
519: 				TStates <= "101";
520: 				IncDec_16 <= "1111";
521: 				Set_Addr_TO <= aSP;
522: 				if DPAIR = "11" then
523: 					Set_BusB_To <= "0111";
524: 				else
525: 					Set_BusB_To(2 downto 1) <= DPAIR;
526: 					Set_BusB_To(0) <= '0';
527: 					Set_BusB_To(3) <= '0';
528: 				end if;
529: 			when 2 =>
530: 				IncDec_16 <= "1111";
531: 				Set_Addr_To <= aSP;
532: 				if DPAIR = "11" then
533: 					Set_BusB_To <= "1011";
534: 				else
535: 					Set_BusB_To(2 downto 1) <= DPAIR;
536: 					Set_BusB_To(0) <= '1';
537: 					Set_BusB_To(3) <= '0';
538: 				end if;
539: 				Write <= '1';
540: 			when 3 =>
541: 				Write <= '1';
542: 			when others => null;
543: 			end case;
544: 		when "11000001"|"11010001"|"11100001"|"11110001" =>
545: 			-- POP qq
546: 			MCycles <= "011";
547: 			case to_integer(unsigned(MCycle)) is
548: 			when 1 =>
549: 				Set_Addr_To <= aSP;
550: 			when 2 =>
551: 				IncDec_16 <= "0111";
552: 				Set_Addr_To <= aSP;
553: 				Read_To_Reg <= '1';
554: 				if DPAIR = "11" then
555: 					Set_BusA_To(3 downto 0) <= "1011";
556: 				else
557: 					Set_BusA_To(2 downto 1) <= DPAIR;
558: 					Set_BusA_To(0) <= '1';
559: 				end if;
560: 			when 3 =>
561: 				IncDec_16 <= "0111";
562: 				Read_To_Reg <= '1';
563: 				if DPAIR = "11" then
564: 					Set_BusA_To(3 downto 0) <= "0111";
565: 				else
566: 					Set_BusA_To(2 downto 1) <= DPAIR;
567: 					Set_BusA_To(0) <= '0';
568: 				end if;
569: 			when others => null;
570: 			end case;
571: 
572: -- EXCHANGE, BLOCK TRANSFER AND SEARCH GROUP
573: 		when "11101011" =>
574: 			if Mode /= 3 then
575: 				-- EX DE,HL
576: 				ExchangeDH <= '1';
577: 			end if;
578: 		when "00001000" =>
579: 			if Mode = 3 then
580: 				-- LD (nn),SP
581: 				MCycles <= "101";
582: 				case to_integer(unsigned(MCycle)) is
583: 				when 2 =>
584: 					Inc_PC <= '1';
585: 					LDZ <= '1';
586: 				when 3 =>
587: 					Set_Addr_To <= aZI;
588: 					Inc_PC <= '1';
589: 					LDW <= '1';
590: 					Set_BusB_To <= "1000";
591: 				when 4 =>
592: 					Inc_WZ <= '1';
593: 					Set_Addr_To <= aZI;
594: 					Write <= '1';
595: 					Set_BusB_To <= "1001";
596: 				when 5 =>
597: 					Write <= '1';
598: 				when others => null;
599: 				end case;
600: 			elsif Mode < 2 then
601: 				-- EX AF,AF'
602: 				ExchangeAF <= '1';
603: 			end if;
604: 		when "11011001" =>
605: 			if Mode = 3 then
606: 				-- RETI
607: 				MCycles <= "011";
608: 				case to_integer(unsigned(MCycle)) is
609: 				when 1 =>
610: 					Set_Addr_TO <= aSP;
611: 				when 2 =>
612: 					IncDec_16 <= "0111";
613: 					Set_Addr_To <= aSP;
614: 					LDZ <= '1';
615: 				when 3 =>
616: 					Jump <= '1';
617: 					IncDec_16 <= "0111";
618: 					I_RETN <= '1';
619: 					SetEI <= '1';
620: 				when others => null;
621: 				end case;
622: 			elsif Mode < 2 then
623: 				-- EXX
624: 				ExchangeRS <= '1';
625: 			end if;
626: 		when "11100011" =>
627: 			if Mode /= 3 then
628: 				-- EX (SP),HL
629: 				MCycles <= "101";
630: 				case to_integer(unsigned(MCycle)) is
631: 				when 1 =>
632: 					Set_Addr_To <= aSP;
633: 				when 2 =>
634: 					Read_To_Reg <= '1';
635: 					Set_BusA_To <= "0101";
636: 					Set_BusB_To <= "0101";
637: 					Set_Addr_To <= aSP;
638: 				when 3 =>
639: 					IncDec_16 <= "0111";
640: 					Set_Addr_To <= aSP;
641: 					TStates <= "100";
642: 					Write <= '1';
643: 				when 4 =>
644: 					Read_To_Reg <= '1';
645: 					Set_BusA_To <= "0100";
646: 					Set_BusB_To <= "0100";
647: 					Set_Addr_To <= aSP;
648: 				when 5 =>
649: 					IncDec_16 <= "1111";
650: 					TStates <= "101";
651: 					Write <= '1';
652: 				when others => null;
653: 				end case;
654: 			end if;
655: 
656: -- 8 BIT ARITHMETIC AND LOGICAL GROUP
657: 		when "10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000111"
658: 			|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001111"
659: 			|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010111"
660: 			|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011111"
661: 			|"10100000"|"10100001"|"10100010"|"10100011"|"10100100"|"10100101"|"10100111"
662: 			|"10101000"|"10101001"|"10101010"|"10101011"|"10101100"|"10101101"|"10101111"
663: 			|"10110000"|"10110001"|"10110010"|"10110011"|"10110100"|"10110101"|"10110111"
664: 			|"10111000"|"10111001"|"10111010"|"10111011"|"10111100"|"10111101"|"10111111" =>
665: 			-- ADD A,r
666: 			-- ADC A,r
667: 			-- SUB A,r
668: 			-- SBC A,r
669: 			-- AND A,r
670: 			-- OR A,r
671: 			-- XOR A,r
672: 			-- CP A,r
673: 			Set_BusB_To(2 downto 0) <= SSS;
674: 			Set_BusA_To(2 downto 0) <= "111";
675: 			Read_To_Reg <= '1';
676: 			Save_ALU <= '1';
677: 		when "10000110"|"10001110"|"10010110"|"10011110"|"10100110"|"10101110"|"10110110"|"10111110" =>
678: 			-- ADD A,(HL)
679: 			-- ADC A,(HL)
680: 			-- SUB A,(HL)
681: 			-- SBC A,(HL)
682: 			-- AND A,(HL)
683: 			-- OR A,(HL)
684: 			-- XOR A,(HL)
685: 			-- CP A,(HL)
686: 			MCycles <= "010";
687: 			case to_integer(unsigned(MCycle)) is
688: 			when 1 =>
689: 				Set_Addr_To <= aXY;
690: 			when 2 =>
691: 				Read_To_Reg <= '1';
692: 				Save_ALU <= '1';
693: 				Set_BusB_To(2 downto 0) <= SSS;
694: 				Set_BusA_To(2 downto 0) <= "111";
695: 			when others => null;
696: 			end case;
697: 		when "11000110"|"11001110"|"11010110"|"11011110"|"11100110"|"11101110"|"11110110"|"11111110" =>
698: 			-- ADD A,n
699: 			-- ADC A,n
700: 			-- SUB A,n
701: 			-- SBC A,n
702: 			-- AND A,n
703: 			-- OR A,n
704: 			-- XOR A,n
705: 			-- CP A,n
706: 			MCycles <= "010";
707: 			if MCycle = "010" then
708: 				Inc_PC <= '1';
709: 				Read_To_Reg <= '1';
710: 				Save_ALU <= '1';
711: 				Set_BusB_To(2 downto 0) <= SSS;
712: 				Set_BusA_To(2 downto 0) <= "111";
713: 			end if;
714: 		when "00000100"|"00001100"|"00010100"|"00011100"|"00100100"|"00101100"|"00111100" =>
715: 			-- INC r
716: 			Set_BusB_To <= "1010";
717: 			Set_BusA_To(2 downto 0) <= DDD;
718: 			Read_To_Reg <= '1';
719: 			Save_ALU <= '1';
720: 			PreserveC <= '1';
721: 			ALU_Op <= "0000";
722: 		when "00110100" =>
723: 			-- INC (HL)
724: 			MCycles <= "011";
725: 			case to_integer(unsigned(MCycle)) is
726: 			when 1 =>
727: 				Set_Addr_To <= aXY;
728: 			when 2 =>
729: 				TStates <= "100";
730: 				Set_Addr_To <= aXY;
731: 				Read_To_Reg <= '1';
732: 				Save_ALU <= '1';
733: 				PreserveC <= '1';
734: 				ALU_Op <= "0000";
735: 				Set_BusB_To <= "1010";
736: 				Set_BusA_To(2 downto 0) <= DDD;
737: 			when 3 =>
738: 				Write <= '1';
739: 			when others => null;
740: 			end case;
741: 		when "00000101"|"00001101"|"00010101"|"00011101"|"00100101"|"00101101"|"00111101" =>
742: 			-- DEC r
743: 			Set_BusB_To <= "1010";
744: 			Set_BusA_To(2 downto 0) <= DDD;
745: 			Read_To_Reg <= '1';
746: 			Save_ALU <= '1';
747: 			PreserveC <= '1';
748: 			ALU_Op <= "0010";
749: 		when "00110101" =>
750: 			-- DEC (HL)
751: 			MCycles <= "011";
752: 			case to_integer(unsigned(MCycle)) is
753: 			when 1 =>
754: 				Set_Addr_To <= aXY;
755: 			when 2 =>
756: 				TStates <= "100";
757: 				Set_Addr_To <= aXY;
758: 				ALU_Op <= "0010";
759: 				Read_To_Reg <= '1';
760: 				Save_ALU <= '1';
761: 				PreserveC <= '1';
762: 				Set_BusB_To <= "1010";
763: 				Set_BusA_To(2 downto 0) <= DDD;
764: 			when 3 =>
765: 				Write <= '1';
766: 			when others => null;
767: 			end case;
768: 
769: -- GENERAL PURPOSE ARITHMETIC AND CPU CONTROL GROUPS
770: 		when "00100111" =>
771: 			-- DAA
772: 			Set_BusA_To(2 downto 0) <= "111";
773: 			Read_To_Reg <= '1';
774: 			ALU_Op <= "1100";
775: 			Save_ALU <= '1';
776: 		when "00101111" =>
777: 			-- CPL
778: 			I_CPL <= '1';
779: 		when "00111111" =>
780: 			-- CCF
781: 			I_CCF <= '1';
782: 		when "00110111" =>
783: 			-- SCF
784: 			I_SCF <= '1';
785: 		when "00000000" =>
786: 			if NMICycle = '1' then
787: 				-- NMI
788: 				MCycles <= "011";
789: 				case to_integer(unsigned(MCycle)) is
790: 				when 1 =>
791: 					TStates <= "101";
792: 					IncDec_16 <= "1111";
793: 					Set_Addr_To <= aSP;
794: 					Set_BusB_To <= "1101";
795: 				when 2 =>
796: 					TStates <= "100";
797: 					Write <= '1';
798: 					IncDec_16 <= "1111";
799: 					Set_Addr_To <= aSP;
800: 					Set_BusB_To <= "1100";
801: 				when 3 =>
802: 					TStates <= "100";
803: 					Write <= '1';
804: 				when others => null;
805: 				end case;
806: 			elsif IntCycle = '1' then
807: 				-- INT (IM 2)
808: 				MCycles <= "101";
809: 				case to_integer(unsigned(MCycle)) is
810: 				when 1 =>
811: 					LDZ <= '1';
812: 					TStates <= "101";
813: 					IncDec_16 <= "1111";
814: 					Set_Addr_To <= aSP;
815: 					Set_BusB_To <= "1101";
816: 				when 2 =>
817: 					TStates <= "100";
818: 					Write <= '1';
819: 					IncDec_16 <= "1111";
820: 					Set_Addr_To <= aSP;
821: 					Set_BusB_To <= "1100";
822: 				when 3 =>
823: 					TStates <= "100";
824: 					Write <= '1';
825: 				when 4 =>
826: 					Inc_PC <= '1';
827: 					LDZ <= '1';
828: 				when 5 =>
829: 					Jump <= '1';
830: 				when others => null;
831: 				end case;
832: 			else
833: 				-- NOP
834: 			end if;
835: 		when "01110110" =>
836: 			-- HALT
837: 			Halt <= '1';
838: 		when "11110011" =>
839: 			-- DI
840: 			SetDI <= '1';
841: 		when "11111011" =>
842: 			-- EI
843: 			SetEI <= '1';
844: 
845: -- 16 BIT ARITHMETIC GROUP
846: 		when "00001001"|"00011001"|"00101001"|"00111001" =>
847: 			-- ADD HL,ss
848: 			MCycles <= "011";
849: 			case to_integer(unsigned(MCycle)) is
850: 			when 2 =>
851: 				NoRead <= '1';
852: 				ALU_Op <= "0000";
853: 				Read_To_Reg <= '1';
854: 				Save_ALU <= '1';
855: 				Set_BusA_To(2 downto 0) <= "101";
856: 				case to_integer(unsigned(IR(5 downto 4))) is
857: 				when 0|1|2 =>
858: 					Set_BusB_To(2 downto 1) <= IR(5 downto 4);
859: 					Set_BusB_To(0) <= '1';
860: 				when others =>
861: 					Set_BusB_To <= "1000";
862: 				end case;
863: 				TStates <= "100";
864: 				Arith16 <= '1';
865: 			when 3 =>
866: 				NoRead <= '1';
867: 				Read_To_Reg <= '1';
868: 				Save_ALU <= '1';
869: 				ALU_Op <= "0001";
870: 				Set_BusA_To(2 downto 0) <= "100";
871: 				case to_integer(unsigned(IR(5 downto 4))) is
872: 				when 0|1|2 =>
873: 					Set_BusB_To(2 downto 1) <= IR(5 downto 4);
874: 				when others =>
875: 					Set_BusB_To <= "1001";
876: 				end case;
877: 				Arith16 <= '1';
878: 			when others =>
879: 			end case;
880: 		when "00000011"|"00010011"|"00100011"|"00110011" =>
881: 			-- INC ss
882: 			TStates <= "110";
883: 			IncDec_16(3 downto 2) <= "01";
884: 			IncDec_16(1 downto 0) <= DPair;
885: 		when "00001011"|"00011011"|"00101011"|"00111011" =>
886: 			-- DEC ss
887: 			TStates <= "110";
888: 			IncDec_16(3 downto 2) <= "11";
889: 			IncDec_16(1 downto 0) <= DPair;
890: 
891: -- ROTATE AND SHIFT GROUP
892: 		when "00000111"
893: 			-- RLCA
894: 			|"00010111"
895: 			-- RLA
896: 			|"00001111"
897: 			-- RRCA
898: 			|"00011111" =>
899: 			-- RRA
900: 			Set_BusA_To(2 downto 0) <= "111";
901: 			ALU_Op <= "1000";
902: 			Read_To_Reg <= '1';
903: 			Save_ALU <= '1';
904: 
905: -- JUMP GROUP
906: 		when "11000011" =>
907: 			-- JP nn
908: 			MCycles <= "011";
909: 			case to_integer(unsigned(MCycle)) is
910: 			when 2 =>
911: 				Inc_PC <= '1';
912: 				LDZ <= '1';
913: 			when 3 =>
914: 				Inc_PC <= '1';
915: 				Jump <= '1';
916: 			when others => null;
917: 			end case;
918: 		when "11000010"|"11001010"|"11010010"|"11011010"|"11100010"|"11101010"|"11110010"|"11111010" =>
919: 			if IR(5) = '1' and Mode = 3 then
920: 				case IRB(4 downto 3) is
921: 				when "00" =>
922: 					-- LD ($FF00+C),A
923: 					MCycles <= "010";
924: 					case to_integer(unsigned(MCycle)) is
925: 					when 1 =>
926: 						Set_Addr_To <= aBC;
927: 						Set_BusB_To	<= "0111";
928: 					when 2 =>
929: 						Write <= '1';
930: 						IORQ <= '1';
931: 					when others =>
932: 					end case;
933: 				when "01" =>
934: 					-- LD (nn),A
935: 					MCycles <= "100";
936: 					case to_integer(unsigned(MCycle)) is
937: 					when 2 =>
938: 						Inc_PC <= '1';
939: 						LDZ <= '1';
940: 					when 3 =>
941: 						Set_Addr_To <= aZI;
942: 						Inc_PC <= '1';
943: 						Set_BusB_To <= "0111";
944: 					when 4 =>
945: 						Write <= '1';
946: 					when others => null;
947: 					end case;
948: 				when "10" =>
949: 					-- LD A,($FF00+C)
950: 					MCycles <= "010";
951: 					case to_integer(unsigned(MCycle)) is
952: 					when 1 =>
953: 						Set_Addr_To <= aBC;
954: 					when 2 =>
955: 						Read_To_Acc <= '1';
956: 						IORQ <= '1';
957: 					when others =>
958: 					end case;
959: 				when "11" =>
960: 					-- LD A,(nn)
961: 					MCycles <= "100";
962: 					case to_integer(unsigned(MCycle)) is
963: 					when 2 =>
964: 						Inc_PC <= '1';
965: 						LDZ <= '1';
966: 					when 3 =>
967: 						Set_Addr_To <= aZI;
968: 						Inc_PC <= '1';
969: 					when 4 =>
970: 						Read_To_Acc <= '1';
971: 					when others => null;
972: 					end case;
973: 				end case;
974: 			else
975: 				-- JP cc,nn
976: 				MCycles <= "011";
977: 				case to_integer(unsigned(MCycle)) is
978: 				when 2 =>
979: 					Inc_PC <= '1';
980: 					LDZ <= '1';
981: 				when 3 =>
982: 					Inc_PC <= '1';
983: 					if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
984: 						Jump <= '1';
985: 					end if;
986: 				when others => null;
987: 				end case;
988: 			end if;
989: 		when "00011000" =>
990: 			if Mode /= 2 then
991: 				-- JR e
992: 				MCycles <= "011";
993: 				case to_integer(unsigned(MCycle)) is
994: 				when 2 =>
995: 					Inc_PC <= '1';
996: 				when 3 =>
997: 					NoRead <= '1';
998: 					JumpE <= '1';
999: 					TStates <= "101";
1000: 				when others => null;
1001: 				end case;
1002: 			end if;
1003: 		when "00111000" =>
1004: 			if Mode /= 2 then
1005: 				-- JR C,e
1006: 				MCycles <= "011";
1007: 				case to_integer(unsigned(MCycle)) is
1008: 				when 2 =>
1009: 					Inc_PC <= '1';
1010: 					if F(Flag_C) = '0' then
1011: 						MCycles <= "010";
1012: 					end if;
1013: 				when 3 =>
1014: 					NoRead <= '1';
1015: 					JumpE <= '1';
1016: 					TStates <= "101";
1017: 				when others => null;
1018: 				end case;
1019: 			end if;
1020: 		when "00110000" =>
1021: 			if Mode /= 2 then
1022: 				-- JR NC,e
1023: 				MCycles <= "011";
1024: 				case to_integer(unsigned(MCycle)) is
1025: 				when 2 =>
1026: 					Inc_PC <= '1';
1027: 					if F(Flag_C) = '1' then
1028: 						MCycles <= "010";
1029: 					end if;
1030: 				when 3 =>
1031: 					NoRead <= '1';
1032: 					JumpE <= '1';
1033: 					TStates <= "101";
1034: 				when others => null;
1035: 				end case;
1036: 			end if;
1037: 		when "00101000" =>
1038: 			if Mode /= 2 then
1039: 				-- JR Z,e
1040: 				MCycles <= "011";
1041: 				case to_integer(unsigned(MCycle)) is
1042: 				when 2 =>
1043: 					Inc_PC <= '1';
1044: 					if F(Flag_Z) = '0' then
1045: 						MCycles <= "010";
1046: 					end if;
1047: 				when 3 =>
1048: 					NoRead <= '1';
1049: 					JumpE <= '1';
1050: 					TStates <= "101";
1051: 				when others => null;
1052: 				end case;
1053: 			end if;
1054: 		when "00100000" =>
1055: 			if Mode /= 2 then
1056: 				-- JR NZ,e
1057: 				MCycles <= "011";
1058: 				case to_integer(unsigned(MCycle)) is
1059: 				when 2 =>
1060: 					Inc_PC <= '1';
1061: 					if F(Flag_Z) = '1' then
1062: 						MCycles <= "010";
1063: 					end if;
1064: 				when 3 =>
1065: 					NoRead <= '1';
1066: 					JumpE <= '1';
1067: 					TStates <= "101";
1068: 				when others => null;
1069: 				end case;
1070: 			end if;
1071: 		when "11101001" =>
1072: 			-- JP (HL)
1073: 			JumpXY <= '1';
1074: 		when "00010000" =>
1075: 			if Mode = 3 then
1076: 				I_DJNZ <= '1';
1077: 			elsif Mode < 2 then
1078: 				-- DJNZ,e
1079: 				MCycles <= "011";
1080: 				case to_integer(unsigned(MCycle)) is
1081: 				when 1 =>
1082: 					TStates <= "101";
1083: 					I_DJNZ <= '1';
1084: 					Set_BusB_To <= "1010";
1085: 					Set_BusA_To(2 downto 0) <= "000";
1086: 					Read_To_Reg <= '1';
1087: 					Save_ALU <= '1';
1088: 					ALU_Op <= "0010";
1089: 				when 2 =>
1090: 					I_DJNZ <= '1';
1091: 					Inc_PC <= '1';
1092: 				when 3 =>
1093: 					NoRead <= '1';
1094: 					JumpE <= '1';
1095: 					TStates <= "101";
1096: 				when others => null;
1097: 				end case;
1098: 			end if;
1099: 
1100: -- CALL AND RETURN GROUP
1101: 		when "11001101" =>
1102: 			-- CALL nn
1103: 			MCycles <= "101";
1104: 			case to_integer(unsigned(MCycle)) is
1105: 			when 2 =>
1106: 				Inc_PC <= '1';
1107: 				LDZ <= '1';
1108: 			when 3 =>
1109: 				IncDec_16 <= "1111";
1110: 				Inc_PC <= '1';
1111: 				TStates <= "100";
1112: 				Set_Addr_To <= aSP;
1113: 				LDW <= '1';
1114: 				Set_BusB_To <= "1101";
1115: 			when 4 =>
1116: 				Write <= '1';
1117: 				IncDec_16 <= "1111";
1118: 				Set_Addr_To <= aSP;
1119: 				Set_BusB_To <= "1100";
1120: 			when 5 =>
1121: 				Write <= '1';
1122: 				Call <= '1';
1123: 			when others => null;
1124: 			end case;
1125: 		when "11000100"|"11001100"|"11010100"|"11011100"|"11100100"|"11101100"|"11110100"|"11111100" =>
1126: 			if IR(5) = '0' or Mode /= 3 then
1127: 				-- CALL cc,nn
1128: 				MCycles <= "101";
1129: 				case to_integer(unsigned(MCycle)) is
1130: 				when 2 =>
1131: 					Inc_PC <= '1';
1132: 					LDZ <= '1';
1133: 				when 3 =>
1134: 					Inc_PC <= '1';
1135: 					LDW <= '1';
1136: 					if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
1137: 						IncDec_16 <= "1111";
1138: 						Set_Addr_TO <= aSP;
1139: 						TStates <= "100";
1140: 						Set_BusB_To <= "1101";
1141: 					else
1142: 						MCycles <= "011";
1143: 					end if;
1144: 				when 4 =>
1145: 					Write <= '1';
1146: 					IncDec_16 <= "1111";
1147: 					Set_Addr_To <= aSP;
1148: 					Set_BusB_To <= "1100";
1149: 				when 5 =>
1150: 					Write <= '1';
1151: 					Call <= '1';
1152: 				when others => null;
1153: 				end case;
1154: 			end if;
1155: 		when "11001001" =>
1156: 			-- RET
1157: 			MCycles <= "011";
1158: 			case to_integer(unsigned(MCycle)) is
1159: 			when 1 =>
1160: 				TStates <= "101";
1161: 				Set_Addr_TO <= aSP;
1162: 			when 2 =>
1163: 				IncDec_16 <= "0111";
1164: 				Set_Addr_To <= aSP;
1165: 				LDZ <= '1';
1166: 			when 3 =>
1167: 				Jump <= '1';
1168: 				IncDec_16 <= "0111";
1169: 			when others => null;
1170: 			end case;
1171: 		when "11000000"|"11001000"|"11010000"|"11011000"|"11100000"|"11101000"|"11110000"|"11111000" =>
1172: 			if IR(5) = '1' and Mode = 3 then
1173: 				case IRB(4 downto 3) is
1174: 				when "00" =>
1175: 					-- LD ($FF00+nn),A
1176: 					MCycles <= "011";
1177: 					case to_integer(unsigned(MCycle)) is
1178: 					when 2 =>
1179: 						Inc_PC <= '1';
1180: 						Set_Addr_To <= aIOA;
1181: 						Set_BusB_To	<= "0111";
1182: 					when 3 =>
1183: 						Write <= '1';
1184: 					when others => null;
1185: 					end case;
1186: 				when "01" =>
1187: 					-- ADD SP,n
1188: 					MCycles <= "011";
1189: 					case to_integer(unsigned(MCycle)) is
1190: 					when 2 =>
1191: 						ALU_Op <= "0000";
1192: 						Inc_PC <= '1';
1193: 						Read_To_Reg <= '1';
1194: 						Save_ALU <= '1';
1195: 						Set_BusA_To <= "1000";
1196: 						Set_BusB_To <= "0110";
1197: 					when 3 =>
1198: 						NoRead <= '1';
1199: 						Read_To_Reg <= '1';
1200: 						Save_ALU <= '1';
1201: 						ALU_Op <= "0001";
1202: 						Set_BusA_To <= "1001";
1203: 						Set_BusB_To <= "1110";	-- Incorrect unsigned !!!!!!!!!!!!!!!!!!!!!
1204: 					when others =>
1205: 					end case;
1206: 				when "10" =>
1207: 					-- LD A,($FF00+nn)
1208: 					MCycles <= "011";
1209: 					case to_integer(unsigned(MCycle)) is
1210: 					when 2 =>
1211: 						Inc_PC <= '1';
1212: 						Set_Addr_To <= aIOA;
1213: 					when 3 =>
1214: 						Read_To_Acc <= '1';
1215: 					when others => null;
1216: 					end case;
1217: 				when "11" =>
1218: 					-- LD HL,SP+n	-- Not correct !!!!!!!!!!!!!!!!!!!
1219: 					MCycles <= "101";
1220: 					case to_integer(unsigned(MCycle)) is
1221: 					when 2 =>
1222: 						Inc_PC <= '1';
1223: 						LDZ <= '1';
1224: 					when 3 =>
1225: 						Set_Addr_To <= aZI;
1226: 						Inc_PC <= '1';
1227: 						LDW <= '1';
1228: 					when 4 =>
1229: 						Set_BusA_To(2 downto 0) <= "101"; -- L
1230: 						Read_To_Reg <= '1';
1231: 						Inc_WZ <= '1';
1232: 						Set_Addr_To <= aZI;
1233: 					when 5 =>
1234: 						Set_BusA_To(2 downto 0) <= "100"; -- H
1235: 						Read_To_Reg <= '1';
1236: 					when others => null;
1237: 					end case;
1238: 				end case;
1239: 			else
1240: 				-- RET cc
1241: 				MCycles <= "011";
1242: 				case to_integer(unsigned(MCycle)) is
1243: 				when 1 =>
1244: 					if is_cc_true(F, to_bitvector(IR(5 downto 3))) then
1245: 						Set_Addr_TO <= aSP;
1246: 					else
1247: 						MCycles <= "001";
1248: 					end if;
1249: 					TStates <= "101";
1250: 				when 2 =>
1251: 					IncDec_16 <= "0111";
1252: 					Set_Addr_To <= aSP;
1253: 					LDZ <= '1';
1254: 				when 3 =>
1255: 					Jump <= '1';
1256: 					IncDec_16 <= "0111";
1257: 				when others => null;
1258: 				end case;
1259: 			end if;
1260: 		when "11000111"|"11001111"|"11010111"|"11011111"|"11100111"|"11101111"|"11110111"|"11111111" =>
1261: 			-- RST p
1262: 			MCycles <= "011";
1263: 			case to_integer(unsigned(MCycle)) is
1264: 			when 1 =>
1265: 				TStates <= "101";
1266: 				IncDec_16 <= "1111";
1267: 				Set_Addr_To <= aSP;
1268: 				Set_BusB_To <= "1101";
1269: 			when 2 =>
1270: 				Write <= '1';
1271: 				IncDec_16 <= "1111";
1272: 				Set_Addr_To <= aSP;
1273: 				Set_BusB_To <= "1100";
1274: 			when 3 =>
1275: 				Write <= '1';
1276: 				RstP <= '1';
1277: 			when others => null;
1278: 			end case;
1279: 
1280: -- INPUT AND OUTPUT GROUP
1281: 		when "11011011" =>
1282: 			if Mode /= 3 then
1283: 				-- IN A,(n)
1284: 				MCycles <= "011";
1285: 				case to_integer(unsigned(MCycle)) is
1286: 				when 2 =>
1287: 					Inc_PC <= '1';
1288: 					Set_Addr_To <= aIOA;
1289: 				when 3 =>
1290: 					Read_To_Acc <= '1';
1291: 					IORQ <= '1';
1292: 				when others => null;
1293: 				end case;
1294: 			end if;
1295: 		when "11010011" =>
1296: 			if Mode /= 3 then
1297: 				-- OUT (n),A
1298: 				MCycles <= "011";
1299: 				case to_integer(unsigned(MCycle)) is
1300: 				when 2 =>
1301: 					Inc_PC <= '1';
1302: 					Set_Addr_To <= aIOA;
1303: 					Set_BusB_To	<= "0111";
1304: 				when 3 =>
1305: 					Write <= '1';
1306: 					IORQ <= '1';
1307: 				when others => null;
1308: 				end case;
1309: 			end if;
1310: 
1311: ------------------------------------------------------------------------------
1312: ------------------------------------------------------------------------------
1313: -- MULTIBYTE INSTRUCTIONS
1314: ------------------------------------------------------------------------------
1315: ------------------------------------------------------------------------------
1316: 
1317: 		when "11001011" =>
1318: 			if Mode /= 2 then
1319: 				Prefix <= "01";
1320: 			end if;
1321: 
1322: 		when "11101101" =>
1323: 			if Mode < 2 then
1324: 				Prefix <= "10";
1325: 			end if;
1326: 
1327: 		when "11011101"|"11111101" =>
1328: 			if Mode < 2 then
1329: 				Prefix <= "11";
1330: 			end if;
1331: 
1332: 		end case;
1333: 
1334: 		when "01" =>
1335: 
1336: ------------------------------------------------------------------------------
1337: --
1338: --	CB prefixed instructions
1339: --
1340: ------------------------------------------------------------------------------
1341: 
1342: 			Set_BusA_To(2 downto 0) <= IR(2 downto 0);
1343: 			Set_BusB_To(2 downto 0) <= IR(2 downto 0);
1344: 
1345: 			case IRB is
1346: 			when "00000000"|"00000001"|"00000010"|"00000011"|"00000100"|"00000101"|"00000111"
1347: 				|"00010000"|"00010001"|"00010010"|"00010011"|"00010100"|"00010101"|"00010111"
1348: 				|"00001000"|"00001001"|"00001010"|"00001011"|"00001100"|"00001101"|"00001111"
1349: 				|"00011000"|"00011001"|"00011010"|"00011011"|"00011100"|"00011101"|"00011111"
1350: 				|"00100000"|"00100001"|"00100010"|"00100011"|"00100100"|"00100101"|"00100111"
1351: 				|"00101000"|"00101001"|"00101010"|"00101011"|"00101100"|"00101101"|"00101111"
1352: 				|"00110000"|"00110001"|"00110010"|"00110011"|"00110100"|"00110101"|"00110111"
1353: 				|"00111000"|"00111001"|"00111010"|"00111011"|"00111100"|"00111101"|"00111111" =>
1354: 				-- RLC r
1355: 				-- RL r
1356: 				-- RRC r
1357: 				-- RR r
1358: 				-- SLA r
1359: 				-- SRA r
1360: 				-- SRL r
1361: 				-- SLL r (Undocumented) / SWAP r
1362: 				if MCycle = "001" then
1363: 					ALU_Op <= "1000";
1364: 					Read_To_Reg <= '1';
1365: 					Save_ALU <= '1';
1366: 				end if;
1367: 			when "00000110"|"00010110"|"00001110"|"00011110"|"00101110"|"00111110"|"00100110"|"00110110" =>
1368: 				-- RLC (HL)
1369: 				-- RL (HL)
1370: 				-- RRC (HL)
1371: 				-- RR (HL)
1372: 				-- SRA (HL)
1373: 				-- SRL (HL)
1374: 				-- SLA (HL)
1375: 				-- SLL (HL) (Undocumented) / SWAP (HL)
1376: 				MCycles <= "011";
1377: 				case to_integer(unsigned(MCycle)) is
1378: 				when 1 | 7 =>
1379: 					Set_Addr_To <= aXY;
1380: 				when 2 =>
1381: 					ALU_Op <= "1000";
1382: 					Read_To_Reg <= '1';
1383: 					Save_ALU <= '1';
1384: 					Set_Addr_To <= aXY;
1385: 					TStates <= "100";
1386: 				when 3 =>
1387: 					Write <= '1';
1388: 				when others =>
1389: 				end case;
1390: 			when "01000000"|"01000001"|"01000010"|"01000011"|"01000100"|"01000101"|"01000111"
1391: 				|"01001000"|"01001001"|"01001010"|"01001011"|"01001100"|"01001101"|"01001111"
1392: 				|"01010000"|"01010001"|"01010010"|"01010011"|"01010100"|"01010101"|"01010111"
1393: 				|"01011000"|"01011001"|"01011010"|"01011011"|"01011100"|"01011101"|"01011111"
1394: 				|"01100000"|"01100001"|"01100010"|"01100011"|"01100100"|"01100101"|"01100111"
1395: 				|"01101000"|"01101001"|"01101010"|"01101011"|"01101100"|"01101101"|"01101111"
1396: 				|"01110000"|"01110001"|"01110010"|"01110011"|"01110100"|"01110101"|"01110111"
1397: 				|"01111000"|"01111001"|"01111010"|"01111011"|"01111100"|"01111101"|"01111111" =>
1398: 				-- BIT b,r
1399: 				if MCycle = "001" then
1400: 					Set_BusB_To(2 downto 0) <= IR(2 downto 0);
1401: 					ALU_Op <= "1001";
1402: 				end if;
1403: 			when "01000110"|"01001110"|"01010110"|"01011110"|"01100110"|"01101110"|"01110110"|"01111110" =>
1404: 				-- BIT b,(HL)
1405: 				MCycles <= "010";
1406: 				case to_integer(unsigned(MCycle)) is
1407: 				when 1 | 7 =>
1408: 					Set_Addr_To <= aXY;
1409: 				when 2 =>
1410: 					ALU_Op <= "1001";
1411: 					TStates <= "100";
1412: 				when others =>
1413: 				end case;
1414: 			when "11000000"|"11000001"|"11000010"|"11000011"|"11000100"|"11000101"|"11000111"
1415: 				|"11001000"|"11001001"|"11001010"|"11001011"|"11001100"|"11001101"|"11001111"
1416: 				|"11010000"|"11010001"|"11010010"|"11010011"|"11010100"|"11010101"|"11010111"
1417: 				|"11011000"|"11011001"|"11011010"|"11011011"|"11011100"|"11011101"|"11011111"
1418: 				|"11100000"|"11100001"|"11100010"|"11100011"|"11100100"|"11100101"|"11100111"
1419: 				|"11101000"|"11101001"|"11101010"|"11101011"|"11101100"|"11101101"|"11101111"
1420: 				|"11110000"|"11110001"|"11110010"|"11110011"|"11110100"|"11110101"|"11110111"
1421: 				|"11111000"|"11111001"|"11111010"|"11111011"|"11111100"|"11111101"|"11111111" =>
1422: 				-- SET b,r
1423: 				if MCycle = "001" then
1424: 					ALU_Op <= "1010";
1425: 					Read_To_Reg <= '1';
1426: 					Save_ALU <= '1';
1427: 				end if;
1428: 			when "11000110"|"11001110"|"11010110"|"11011110"|"11100110"|"11101110"|"11110110"|"11111110" =>
1429: 				-- SET b,(HL)
1430: 				MCycles <= "011";
1431: 				case to_integer(unsigned(MCycle)) is
1432: 				when 1 | 7 =>
1433: 					Set_Addr_To <= aXY;
1434: 				when 2 =>
1435: 					ALU_Op <= "1010";
1436: 					Read_To_Reg <= '1';
1437: 					Save_ALU <= '1';
1438: 					Set_Addr_To <= aXY;
1439: 					TStates <= "100";
1440: 				when 3 =>
1441: 					Write <= '1';
1442: 				when others =>
1443: 				end case;
1444: 			when "10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000111"
1445: 				|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001111"
1446: 				|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010111"
1447: 				|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011111"
1448: 				|"10100000"|"10100001"|"10100010"|"10100011"|"10100100"|"10100101"|"10100111"
1449: 				|"10101000"|"10101001"|"10101010"|"10101011"|"10101100"|"10101101"|"10101111"
1450: 				|"10110000"|"10110001"|"10110010"|"10110011"|"10110100"|"10110101"|"10110111"
1451: 				|"10111000"|"10111001"|"10111010"|"10111011"|"10111100"|"10111101"|"10111111" =>
1452: 				-- RES b,r
1453: 				if MCycle = "001" then
1454: 					ALU_Op <= "1011";
1455: 					Read_To_Reg <= '1';
1456: 					Save_ALU <= '1';
1457: 				end if;
1458: 			when "10000110"|"10001110"|"10010110"|"10011110"|"10100110"|"10101110"|"10110110"|"10111110" =>
1459: 				-- RES b,(HL)
1460: 				MCycles <= "011";
1461: 				case to_integer(unsigned(MCycle)) is
1462: 				when 1 | 7 =>
1463: 					Set_Addr_To <= aXY;
1464: 				when 2 =>
1465: 					ALU_Op <= "1011";
1466: 					Read_To_Reg <= '1';
1467: 					Save_ALU <= '1';
1468: 					Set_Addr_To <= aXY;
1469: 					TStates <= "100";
1470: 				when 3 =>
1471: 					Write <= '1';
1472: 				when others =>
1473: 				end case;
1474: 			end case;
1475: 
1476: 		when others =>
1477: 
1478: ------------------------------------------------------------------------------
1479: --
1480: --	ED prefixed instructions
1481: --
1482: ------------------------------------------------------------------------------
1483: 
1484: 			case IRB is
1485: 			when "00000000"|"00000001"|"00000010"|"00000011"|"00000100"|"00000101"|"00000110"|"00000111"
1486: 				|"00001000"|"00001001"|"00001010"|"00001011"|"00001100"|"00001101"|"00001110"|"00001111"
1487: 				|"00010000"|"00010001"|"00010010"|"00010011"|"00010100"|"00010101"|"00010110"|"00010111"
1488: 				|"00011000"|"00011001"|"00011010"|"00011011"|"00011100"|"00011101"|"00011110"|"00011111"
1489: 				|"00100000"|"00100001"|"00100010"|"00100011"|"00100100"|"00100101"|"00100110"|"00100111"
1490: 				|"00101000"|"00101001"|"00101010"|"00101011"|"00101100"|"00101101"|"00101110"|"00101111"
1491: 				|"00110000"|"00110001"|"00110010"|"00110011"|"00110100"|"00110101"|"00110110"|"00110111"
1492: 				|"00111000"|"00111001"|"00111010"|"00111011"|"00111100"|"00111101"|"00111110"|"00111111"
1493: 
1494: 
1495: 				|"10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000110"|"10000111"
1496: 				|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001110"|"10001111"
1497: 				|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010110"|"10010111"
1498: 				|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011110"|"10011111"
1499: 				|                                            "10100100"|"10100101"|"10100110"|"10100111"
1500: 				|                                            "10101100"|"10101101"|"10101110"|"10101111"
1501: 				|                                            "10110100"|"10110101"|"10110110"|"10110111"
1502: 				|                                            "10111100"|"10111101"|"10111110"|"10111111"
1503: 				|"11000000"|"11000001"|"11000010"|"11000011"|"11000100"|"11000101"|"11000110"|"11000111"
1504: 				|"11001000"|"11001001"|"11001010"|"11001011"|"11001100"|"11001101"|"11001110"|"11001111"
1505: 				|"11010000"|"11010001"|"11010010"|"11010011"|"11010100"|"11010101"|"11010110"|"11010111"
1506: 				|"11011000"|"11011001"|"11011010"|"11011011"|"11011100"|"11011101"|"11011110"|"11011111"
1507: 				|"11100000"|"11100001"|"11100010"|"11100011"|"11100100"|"11100101"|"11100110"|"11100111"
1508: 				|"11101000"|"11101001"|"11101010"|"11101011"|"11101100"|"11101101"|"11101110"|"11101111"
1509: 				|"11110000"|"11110001"|"11110010"|"11110011"|"11110100"|"11110101"|"11110110"|"11110111"
1510: 				|"11111000"|"11111001"|"11111010"|"11111011"|"11111100"|"11111101"|"11111110"|"11111111" =>
1511: 				null; -- NOP, undocumented
1512: 			when "01111110"|"01111111" =>
1513: 				-- NOP, undocumented
1514: 				null;
1515: -- 8 BIT LOAD GROUP
1516: 			when "01010111" =>
1517: 				-- LD A,I
1518: 				Special_LD <= "100";
1519: 				TStates <= "101";
1520: 			when "01011111" =>
1521: 				-- LD A,R
1522: 				Special_LD <= "101";
1523: 				TStates <= "101";
1524: 			when "01000111" =>
1525: 				-- LD I,A
1526: 				Special_LD <= "110";
1527: 				TStates <= "101";
1528: 			when "01001111" =>
1529: 				-- LD R,A
1530: 				Special_LD <= "111";
1531: 				TStates <= "101";
1532: -- 16 BIT LOAD GROUP
1533: 			when "01001011"|"01011011"|"01101011"|"01111011" =>
1534: 				-- LD dd,(nn)
1535: 				MCycles <= "101";
1536: 				case to_integer(unsigned(MCycle)) is
1537: 				when 2 =>
1538: 					Inc_PC <= '1';
1539: 					LDZ <= '1';
1540: 				when 3 =>
1541: 					Set_Addr_To <= aZI;
1542: 					Inc_PC <= '1';
1543: 					LDW <= '1';
1544: 				when 4 =>
1545: 					Read_To_Reg <= '1';
1546: 					if IR(5 downto 4) = "11" then
1547: 						Set_BusA_To <= "1000";
1548: 					else
1549: 						Set_BusA_To(2 downto 1) <= IR(5 downto 4);
1550: 						Set_BusA_To(0) <= '1';
1551: 					end if;
1552: 					Inc_WZ <= '1';
1553: 					Set_Addr_To <= aZI;
1554: 				when 5 =>
1555: 					Read_To_Reg <= '1';
1556: 					if IR(5 downto 4) = "11" then
1557: 						Set_BusA_To <= "1001";
1558: 					else
1559: 						Set_BusA_To(2 downto 1) <= IR(5 downto 4);
1560: 						Set_BusA_To(0) <= '0';
1561: 					end if;
1562: 				when others => null;
1563: 				end case;
1564: 			when "01000011"|"01010011"|"01100011"|"01110011" =>
1565: 				-- LD (nn),dd
1566: 				MCycles <= "101";
1567: 				case to_integer(unsigned(MCycle)) is
1568: 				when 2 =>
1569: 					Inc_PC <= '1';
1570: 					LDZ <= '1';
1571: 				when 3 =>
1572: 					Set_Addr_To <= aZI;
1573: 					Inc_PC <= '1';
1574: 					LDW <= '1';
1575: 					if IR(5 downto 4) = "11" then
1576: 						Set_BusB_To <= "1000";
1577: 					else
1578: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1579: 						Set_BusB_To(0) <= '1';
1580: 						Set_BusB_To(3) <= '0';
1581: 					end if;
1582: 				when 4 =>
1583: 					Inc_WZ <= '1';
1584: 					Set_Addr_To <= aZI;
1585: 					Write <= '1';
1586: 					if IR(5 downto 4) = "11" then
1587: 						Set_BusB_To <= "1001";
1588: 					else
1589: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1590: 						Set_BusB_To(0) <= '0';
1591: 						Set_BusB_To(3) <= '0';
1592: 					end if;
1593: 				when 5 =>
1594: 					Write <= '1';
1595: 				when others => null;
1596: 				end case;
1597: 			when "10100000" | "10101000" | "10110000" | "10111000" =>
1598: 				-- LDI, LDD, LDIR, LDDR
1599: 				MCycles <= "100";
1600: 				case to_integer(unsigned(MCycle)) is
1601: 				when 1 =>
1602: 					Set_Addr_To <= aXY;
1603: 					IncDec_16 <= "1100"; -- BC
1604: 				when 2 =>
1605: 					Set_BusB_To <= "0110";
1606: 					Set_BusA_To(2 downto 0) <= "111";
1607: 					ALU_Op <= "0000";
1608: 					Set_Addr_To <= aDE;
1609: 					if IR(3) = '0' then
1610: 						IncDec_16 <= "0110"; -- IX
1611: 					else
1612: 						IncDec_16 <= "1110";
1613: 					end if;
1614: 				when 3 =>
1615: 					I_BT <= '1';
1616: 					TStates <= "101";
1617: 					Write <= '1';
1618: 					if IR(3) = '0' then
1619: 						IncDec_16 <= "0101"; -- DE
1620: 					else
1621: 						IncDec_16 <= "1101";
1622: 					end if;
1623: 				when 4 =>
1624: 					NoRead <= '1';
1625: 					TStates <= "101";
1626: 				when others => null;
1627: 				end case;
1628: 			when "10100001" | "10101001" | "10110001" | "10111001" =>
1629: 				-- CPI, CPD, CPIR, CPDR
1630: 				MCycles <= "100";
1631: 				case to_integer(unsigned(MCycle)) is
1632: 				when 1 =>
1633: 					Set_Addr_To <= aXY;
1634: 					IncDec_16 <= "1100"; -- BC
1635: 				when 2 =>
1636: 					Set_BusB_To <= "0110";
1637: 					Set_BusA_To(2 downto 0) <= "111";
1638: 					ALU_Op <= "0111";
1639: 					Save_ALU <= '1';
1640: 					PreserveC <= '1';
1641: 					if IR(3) = '0' then
1642: 						IncDec_16 <= "0110";
1643: 					else
1644: 						IncDec_16 <= "1110";
1645: 					end if;
1646: 				when 3 =>
1647: 					NoRead <= '1';
1648: 					I_BC <= '1';
1649: 					TStates <= "101";
1650: 				when 4 =>
1651: 					NoRead <= '1';
1652: 					TStates <= "101";
1653: 				when others => null;
1654: 				end case;
1655: 			when "01000100"|"01001100"|"01010100"|"01011100"|"01100100"|"01101100"|"01110100"|"01111100" =>
1656: 				-- NEG
1657: 				Alu_OP <= "0010";
1658: 				Set_BusB_To <= "0111";
1659: 				Set_BusA_To <= "1010";
1660: 				Read_To_Acc <= '1';
1661: 				Save_ALU <= '1';
1662: 			when "01000110"|"01001110"|"01100110"|"01101110" =>
1663: 				-- IM 0
1664: 				IMode <= "00";
1665: 			when "01010110"|"01110110" =>
1666: 				-- IM 1
1667: 				IMode <= "01";
1668: 			when "01011110"|"01110111" =>
1669: 				-- IM 2
1670: 				IMode <= "10";
1671: -- 16 bit arithmetic
1672: 			when "01001010"|"01011010"|"01101010"|"01111010" =>
1673: 				-- ADC HL,ss
1674: 				MCycles <= "011";
1675: 				case to_integer(unsigned(MCycle)) is
1676: 				when 2 =>
1677: 					NoRead <= '1';
1678: 					ALU_Op <= "0001";
1679: 					Read_To_Reg <= '1';
1680: 					Save_ALU <= '1';
1681: 					Set_BusA_To(2 downto 0) <= "101";
1682: 					case to_integer(unsigned(IR(5 downto 4))) is
1683: 					when 0|1|2 =>
1684: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1685: 					Set_BusB_To(0) <= '1';
1686: 						when others =>
1687: 						Set_BusB_To <= "1000";
1688: 					end case;
1689: 					TStates <= "100";
1690: 				when 3 =>
1691: 					NoRead <= '1';
1692: 					Read_To_Reg <= '1';
1693: 					Save_ALU <= '1';
1694: 					ALU_Op <= "0001";
1695: 					Set_BusA_To(2 downto 0) <= "100";
1696: 					case to_integer(unsigned(IR(5 downto 4))) is
1697: 					when 0|1|2 =>
1698: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1699: 						Set_BusB_To(0) <= '0';
1700: 					when others =>
1701: 						Set_BusB_To <= "1001";
1702: 					end case;
1703: 				when others =>
1704: 				end case;
1705: 			when "01000010"|"01010010"|"01100010"|"01110010" =>
1706: 				-- SBC HL,ss
1707: 				MCycles <= "011";
1708: 				case to_integer(unsigned(MCycle)) is
1709: 				when 2 =>
1710: 					NoRead <= '1';
1711: 					ALU_Op <= "0011";
1712: 					Read_To_Reg <= '1';
1713: 					Save_ALU <= '1';
1714: 					Set_BusA_To(2 downto 0) <= "101";
1715: 					case to_integer(unsigned(IR(5 downto 4))) is
1716: 					when 0|1|2 =>
1717: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1718: 						Set_BusB_To(0) <= '1';
1719: 					when others =>
1720: 						Set_BusB_To <= "1000";
1721: 					end case;
1722: 					TStates <= "100";
1723: 				when 3 =>
1724: 					NoRead <= '1';
1725: 					ALU_Op <= "0011";
1726: 					Read_To_Reg <= '1';
1727: 					Save_ALU <= '1';
1728: 					Set_BusA_To(2 downto 0) <= "100";
1729: 					case to_integer(unsigned(IR(5 downto 4))) is
1730: 					when 0|1|2 =>
1731: 						Set_BusB_To(2 downto 1) <= IR(5 downto 4);
1732: 					when others =>
1733: 							Set_BusB_To <= "1001";
1734: 					end case;
1735: 				when others =>
1736: 				end case;
1737: 			when "01101111" =>
1738: 				-- RLD
1739: 				MCycles <= "100";
1740: 				case to_integer(unsigned(MCycle)) is
1741: 				when 2 =>
1742: 					NoRead <= '1';
1743: 					Set_Addr_To <= aXY;
1744: 				when 3 =>
1745: 					Read_To_Reg <= '1';
1746: 					Set_BusB_To(2 downto 0) <= "110";
1747: 					Set_BusA_To(2 downto 0) <= "111";
1748: 					ALU_Op <= "1101";
1749: 					TStates <= "100";
1750: 					Set_Addr_To <= aXY;
1751: 					Save_ALU <= '1';
1752: 				when 4 =>
1753: 					I_RLD <= '1';
1754: 					Write <= '1';
1755: 				when others =>
1756: 				end case;
1757: 			when "01100111" =>
1758: 				-- RRD
1759: 				MCycles <= "100";
1760: 				case to_integer(unsigned(MCycle)) is
1761: 				when 2 =>
1762: 					Set_Addr_To <= aXY;
1763: 				when 3 =>
1764: 					Read_To_Reg <= '1';
1765: 					Set_BusB_To(2 downto 0) <= "110";
1766: 					Set_BusA_To(2 downto 0) <= "111";
1767: 					ALU_Op <= "1110";
1768: 					TStates <= "100";
1769: 					Set_Addr_To <= aXY;
1770: 					Save_ALU <= '1';
1771: 				when 4 =>
1772: 					I_RRD <= '1';
1773: 					Write <= '1';
1774: 				when others =>
1775: 				end case;
1776: 			when "01000101"|"01001101"|"01010101"|"01011101"|"01100101"|"01101101"|"01110101"|"01111101" =>
1777: 				-- RETI, RETN
1778: 				MCycles <= "011";
1779: 				case to_integer(unsigned(MCycle)) is
1780: 				when 1 =>
1781: 					Set_Addr_TO <= aSP;
1782: 				when 2 =>
1783: 					IncDec_16 <= "0111";
1784: 					Set_Addr_To <= aSP;
1785: 					LDZ <= '1';
1786: 				when 3 =>
1787: 					Jump <= '1';
1788: 					IncDec_16 <= "0111";
1789: 					I_RETN <= '1';
1790: 				when others => null;
1791: 				end case;
1792: 			when "01000000"|"01001000"|"01010000"|"01011000"|"01100000"|"01101000"|"01110000"|"01111000" =>
1793: 				-- IN r,(C)
1794: 				MCycles <= "010";
1795: 				case to_integer(unsigned(MCycle)) is
1796: 				when 1 =>
1797: 					Set_Addr_To <= aBC;
1798: 				when 2 =>
1799: 					IORQ <= '1';
1800: 					if IR(5 downto 3) /= "110" then
1801: 						Read_To_Reg <= '1';
1802: 						Set_BusA_To(2 downto 0) <= IR(5 downto 3);
1803: 					end if;
1804: 					I_INRC <= '1';
1805: 				when others =>
1806: 				end case;
1807: 			when "01000001"|"01001001"|"01010001"|"01011001"|"01100001"|"01101001"|"01110001"|"01111001" =>
1808: 				-- OUT (C),r
1809: 				-- OUT (C),0
1810: 				MCycles <= "010";
1811: 				case to_integer(unsigned(MCycle)) is
1812: 				when 1 =>
1813: 					Set_Addr_To <= aBC;
1814: 					Set_BusB_To(2 downto 0)	<= IR(5 downto 3);
1815: 					if IR(5 downto 3) = "110" then
1816: 						Set_BusB_To(3) <= '1';
1817: 					end if;
1818: 				when 2 =>
1819: 					Write <= '1';
1820: 					IORQ <= '1';
1821: 				when others =>
1822: 				end case;
1823: 			when "10100010" | "10101010" | "10110010" | "10111010" =>
1824: 				-- INI, IND, INIR, INDR
1825: 				MCycles <= "100";
1826: 				case to_integer(unsigned(MCycle)) is
1827: 				when 1 =>
1828: 					Set_Addr_To <= aBC;
1829: 					Set_BusB_To <= "1010";
1830: 					Set_BusA_To <= "0000";
1831: 					Read_To_Reg <= '1';
1832: 					Save_ALU <= '1';
1833: 					ALU_Op <= "0010";
1834: 				when 2 =>
1835: 					IORQ <= '1';
1836: 					Set_BusB_To <= "0110";
1837: 					Set_Addr_To <= aXY;
1838: 				when 3 =>
1839: 					if IR(3) = '0' then
1840: 						IncDec_16 <= "0010";
1841: 					else
1842: 						IncDec_16 <= "1010";
1843: 					end if;
1844: 					TStates <= "100";
1845: 					Write <= '1';
1846: 					I_BTR <= '1';
1847: 				when 4 =>
1848: 					NoRead <= '1';
1849: 					TStates <= "101";
1850: 				when others => null;
1851: 				end case;
1852: 			when "10100011" | "10101011" | "10110011" | "10111011" =>
1853: 				-- OUTI, OUTD, OTIR, OTDR
1854: 				MCycles <= "100";
1855: 				case to_integer(unsigned(MCycle)) is
1856: 				when 1 =>
1857: 					TStates <= "101";
1858: 					Set_Addr_To <= aXY;
1859: 					Set_BusB_To <= "1010";
1860: 					Set_BusA_To <= "0000";
1861: 					Read_To_Reg <= '1';
1862: 					Save_ALU <= '1';
1863: 					ALU_Op <= "0010";
1864: 				when 2 =>
1865: 					Set_BusB_To <= "0110";
1866: 					Set_Addr_To <= aBC;
1867: 				when 3 =>
1868: 					if IR(3) = '0' then
1869: 						IncDec_16 <= "0010";
1870: 					else
1871: 						IncDec_16 <= "1010";
1872: 					end if;
1873: 					IORQ <= '1';
1874: 					Write <= '1';
1875: 					I_BTR <= '1';
1876: 				when 4 =>
1877: 					NoRead <= '1';
1878: 					TStates <= "101";
1879: 				when others => null;
1880: 				end case;
1881: 			end case;
1882: 
1883: 		end case;
1884: 
1885: 		if Mode = 1 then
1886: 			if MCycle = "001" then
1887: --				TStates <= "100";
1888: 			else
1889: 				TStates <= "011";
1890: 			end if;
1891: 		end if;
1892: 
1893: 		if Mode = 3 then
1894: 			if MCycle = "001" then
1895: --				TStates <= "100";
1896: 			else
1897: 				TStates <= "100";
1898: 			end if;
1899: 		end if;
1900: 
1901: 		if Mode < 2 then
1902: 			if MCycle = "110" then
1903: 				Inc_PC <= '1';
1904: 				if Mode = 1 then
1905: 					Set_Addr_To <= aXY;
1906: 					TStates <= "100";
1907: 					Set_BusB_To(2 downto 0) <= SSS;
1908: 					Set_BusB_To(3) <= '0';
1909: 				end if;
1910: 				if IRB = "00110110" or IRB = "11001011" then
1911: 					Set_Addr_To <= aNone;
1912: 				end if;
1913: 			end if;
1914: 			if MCycle = "111" then
1915: 				if Mode = 0 then
1916: 					TStates <= "101";
1917: 				end if;
1918: 				if ISet /= "01" then
1919: 					Set_Addr_To <= aXY;
1920: 				end if;
1921: 				Set_BusB_To(2 downto 0) <= SSS;
1922: 				Set_BusB_To(3) <= '0';
1923: 				if IRB = "00110110" or ISet = "01" then
1924: 					-- LD (HL),n
1925: 					Inc_PC <= '1';
1926: 				else
1927: 					NoRead <= '1';
1928: 				end if;
1929: 			end if;
1930: 		end if;
1931: 
1932: 	end process;
1933: 
1934: end;

(End of file - total 1934 lines)
</content>
```

---

## Assistant (Plan · Claude Opus 4.8 · 5.7s)

Now I understand the ED-prefix decode structure. Let me look at the T80.vhd to understand how the microcode signals are consumed, especially the register/address handling and how multi-cycle reads work. The NEXT operation needs: DE→address, read mem to E, inc, read mem to D, inc, then jump to (HL... well actually to W which is now the cell read). Let me re-read the NEXT semantics carefully and study the datapath.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80.vhd"
}
```

**Output:**
```
<path>/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80.vhd</path>
<type>file</type>
<content>
1: --
2: -- Z80 compatible microprocessor core
3: --
4: -- Version : 0247
5: --
6: -- Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
7: --
8: -- All rights reserved
9: --
10: -- Redistribution and use in source and synthezised forms, with or without
11: -- modification, are permitted provided that the following conditions are met:
12: --
13: -- Redistributions of source code must retain the above copyright notice,
14: -- this list of conditions and the following disclaimer.
15: --
16: -- Redistributions in synthesized form must reproduce the above copyright
17: -- notice, this list of conditions and the following disclaimer in the
18: -- documentation and/or other materials provided with the distribution.
19: --
20: -- Neither the name of the author nor the names of other contributors may
21: -- be used to endorse or promote products derived from this software without
22: -- specific prior written permission.
23: --
24: -- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
25: -- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
26: -- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
27: -- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
28: -- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
29: -- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
30: -- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
31: -- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
32: -- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
33: -- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
34: -- POSSIBILITY OF SUCH DAMAGE.
35: --
36: -- Please report bugs to the author, but before you do so, please
37: -- make sure that this is not a derivative work and that
38: -- you have the latest version of this file.
39: --
40: -- The latest version of this file can be found at:
41: --	http://www.opencores.org/cvsweb.shtml/t80/
42: --
43: -- Limitations :
44: --
45: -- File history :
46: --
47: --	0208 : First complete release
48: --
49: --	0210 : Fixed wait and halt
50: --
51: --	0211 : Fixed Refresh addition and IM 1
52: --
53: --	0214 : Fixed mostly flags, only the block instructions now fail the zex regression test
54: --
55: --	0232 : Removed refresh address output for Mode > 1 and added DJNZ M1_n fix by Mike Johnson
56: --
57: --	0235 : Added clock enable and IM 2 fix by Mike Johnson
58: --
59: --	0237 : Changed 8080 I/O address output, added IntE output
60: --
61: --	0238 : Fixed (IX/IY+d) timing and 16 bit ADC and SBC zero flag
62: --
63: --	0240 : Added interrupt ack fix by Mike Johnson, changed (IX/IY+d) timing and changed flags in GB mode
64: --
65: --	0242 : Added I/O wait, fixed refresh address, moved some registers to RAM
66: --
67: --	0247 : Fixed bus req/ack cycle
68: --
69: 
70: library IEEE;
71: use IEEE.std_logic_1164.all;
72: use IEEE.numeric_std.all;
73: use work.T80_Pack.all;
74: 
75: entity T80 is
76: 	generic(
77: 		Mode : integer := 0;	-- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
78: 		IOWait : integer := 0;	-- 1 => Single cycle I/O, 1 => Std I/O cycle
79: 		Flag_C : integer := 0;
80: 		Flag_N : integer := 1;
81: 		Flag_P : integer := 2;
82: 		Flag_X : integer := 3;
83: 		Flag_H : integer := 4;
84: 		Flag_Y : integer := 5;
85: 		Flag_Z : integer := 6;
86: 		Flag_S : integer := 7
87: 	);
88: 	port(
89: 		RESET_n		: in std_logic;
90: 		CLK_n		: in std_logic;
91: 		CEN			: in std_logic;
92: 		WAIT_n		: in std_logic;
93: 		INT_n		: in std_logic;
94: 		NMI_n		: in std_logic;
95: 		BUSRQ_n		: in std_logic;
96: 		M1_n		: out std_logic;
97: 		IORQ		: out std_logic;
98: 		NoRead		: out std_logic;
99: 		Write		: out std_logic;
100: 		RFSH_n		: out std_logic;
101: 		HALT_n		: out std_logic;
102: 		BUSAK_n		: out std_logic;
103: 		A			: out std_logic_vector(15 downto 0);
104: 		DInst		: in std_logic_vector(7 downto 0);
105: 		DI			: in std_logic_vector(7 downto 0);
106: 		DO			: out std_logic_vector(7 downto 0);
107: 		MC			: out std_logic_vector(2 downto 0);
108: 		TS			: out std_logic_vector(2 downto 0);
109: 		IntCycle_n	: out std_logic;
110: 		IntE		: out std_logic;
111: 		Stop		: out std_logic;
112: 		REG		: out std_logic_vector(211 downto 0) -- IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
113: 	);
114: end T80;
115: 
116: architecture rtl of T80 is
117: 
118: 	constant aNone	: std_logic_vector(2 downto 0) := "111";
119: 	constant aBC	: std_logic_vector(2 downto 0) := "000";
120: 	constant aDE	: std_logic_vector(2 downto 0) := "001";
121: 	constant aXY	: std_logic_vector(2 downto 0) := "010";
122: 	constant aIOA	: std_logic_vector(2 downto 0) := "100";
123: 	constant aSP	: std_logic_vector(2 downto 0) := "101";
124: 	constant aZI	: std_logic_vector(2 downto 0) := "110";
125: 
126: 	-- Registers
127: 	signal ACC, F			: std_logic_vector(7 downto 0);
128: 	signal Ap, Fp			: std_logic_vector(7 downto 0);
129: 	signal I				: std_logic_vector(7 downto 0);
130: 	signal R				: unsigned(7 downto 0);
131: 	signal SP, PC			: unsigned(15 downto 0);
132: 	signal RegDIH			: std_logic_vector(7 downto 0);
133: 	signal RegDIL			: std_logic_vector(7 downto 0);
134: 	signal RegBusA			: std_logic_vector(15 downto 0);
135: 	signal RegBusB			: std_logic_vector(15 downto 0);
136: 	signal RegBusC			: std_logic_vector(15 downto 0);
137: 	signal RegAddrA_r		: std_logic_vector(2 downto 0);
138: 	signal RegAddrA			: std_logic_vector(2 downto 0);
139: 	signal RegAddrB_r		: std_logic_vector(2 downto 0);
140: 	signal RegAddrB			: std_logic_vector(2 downto 0);
141: 	signal RegAddrC			: std_logic_vector(2 downto 0);
142: 	signal RegWEH			: std_logic;
143: 	signal RegWEL			: std_logic;
144: 	signal Alternate		: std_logic;
145: 
146: 	-- Help Registers
147: 	signal TmpAddr			: std_logic_vector(15 downto 0);	-- Temporary address register
148: 	signal IR				: std_logic_vector(7 downto 0);		-- Instruction register
149: 	signal ISet				: std_logic_vector(1 downto 0);		-- Instruction set selector
150: 	signal RegBusA_r		: std_logic_vector(15 downto 0);
151: 
152: 	signal ID16				: signed(15 downto 0);
153: 	signal Save_Mux			: std_logic_vector(7 downto 0);
154: 
155: 	signal TState			: unsigned(2 downto 0);
156: 	signal MCycle			: std_logic_vector(2 downto 0);
157: 	signal IntE_FF1			: std_logic;
158: 	signal IntE_FF2			: std_logic;
159: 	signal Halt_FF			: std_logic;
160: 	signal BusReq_s			: std_logic;
161: 	signal BusAck			: std_logic;
162: 	signal ClkEn			: std_logic;
163: 	signal NMI_s			: std_logic;
164: 	signal INT_s			: std_logic;
165: 	signal IStatus			: std_logic_vector(1 downto 0);
166: 
167: 	signal DI_Reg			: std_logic_vector(7 downto 0);
168: 	signal T_Res			: std_logic;
169: 	signal XY_State			: std_logic_vector(1 downto 0);
170: 	signal Pre_XY_F_M		: std_logic_vector(2 downto 0);
171: 	signal NextIs_XY_Fetch	: std_logic;
172: 	signal XY_Ind			: std_logic;
173: 	signal No_BTR			: std_logic;
174: 	signal BTR_r			: std_logic;
175: 	signal Auto_Wait		: std_logic;
176: 	signal Auto_Wait_t1		: std_logic;
177: 	signal Auto_Wait_t2		: std_logic;
178: 	signal IncDecZ			: std_logic;
179: 
180: 	-- ALU signals
181: 	signal BusB				: std_logic_vector(7 downto 0);
182: 	signal BusA				: std_logic_vector(7 downto 0);
183: 	signal ALU_Q			: std_logic_vector(7 downto 0);
184: 	signal F_Out			: std_logic_vector(7 downto 0);
185: 
186: 	-- Registered micro code outputs
187: 	signal Read_To_Reg_r	: std_logic_vector(4 downto 0);
188: 	signal Arith16_r		: std_logic;
189: 	signal Z16_r			: std_logic;
190: 	signal ALU_Op_r			: std_logic_vector(3 downto 0);
191: 	signal Save_ALU_r		: std_logic;
192: 	signal PreserveC_r		: std_logic;
193: 	signal MCycles			: std_logic_vector(2 downto 0);
194: 
195: 	-- Micro code outputs
196: 	signal MCycles_d		: std_logic_vector(2 downto 0);
197: 	signal TStates			: std_logic_vector(2 downto 0);
198: 	signal IntCycle			: std_logic;
199: 	signal NMICycle			: std_logic;
200: 	signal Inc_PC			: std_logic;
201: 	signal Inc_WZ			: std_logic;
202: 	signal IncDec_16		: std_logic_vector(3 downto 0);
203: 	signal Prefix			: std_logic_vector(1 downto 0);
204: 	signal Read_To_Acc		: std_logic;
205: 	signal Read_To_Reg		: std_logic;
206: 	signal Set_BusB_To		: std_logic_vector(3 downto 0);
207: 	signal Set_BusA_To		: std_logic_vector(3 downto 0);
208: 	signal ALU_Op			: std_logic_vector(3 downto 0);
209: 	signal Save_ALU			: std_logic;
210: 	signal PreserveC		: std_logic;
211: 	signal Arith16			: std_logic;
212: 	signal Set_Addr_To		: std_logic_vector(2 downto 0);
213: 	signal Jump				: std_logic;
214: 	signal JumpE			: std_logic;
215: 	signal JumpXY			: std_logic;
216: 	signal Call				: std_logic;
217: 	signal RstP				: std_logic;
218: 	signal LDZ				: std_logic;
219: 	signal LDW				: std_logic;
220: 	signal LDSPHL			: std_logic;
221: 	signal IORQ_i			: std_logic;
222: 	signal Special_LD		: std_logic_vector(2 downto 0);
223: 	signal ExchangeDH		: std_logic;
224: 	signal ExchangeRp		: std_logic;
225: 	signal ExchangeAF		: std_logic;
226: 	signal ExchangeRS		: std_logic;
227: 	signal I_DJNZ			: std_logic;
228: 	signal I_CPL			: std_logic;
229: 	signal I_CCF			: std_logic;
230: 	signal I_SCF			: std_logic;
231: 	signal I_RETN			: std_logic;
232: 	signal I_BT				: std_logic;
233: 	signal I_BC				: std_logic;
234: 	signal I_BTR			: std_logic;
235: 	signal I_RLD			: std_logic;
236: 	signal I_RRD			: std_logic;
237: 	signal I_INRC			: std_logic;
238: 	signal SetDI			: std_logic;
239: 	signal SetEI			: std_logic;
240: 	signal IMode			: std_logic_vector(1 downto 0);
241: 	signal Halt				: std_logic;
242: 	signal DOR			: std_logic_vector(127 downto 0);
243: 
244: begin
245:         -- IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
246: 	REG <= IntE_FF2 & IntE_FF1 & IStatus &
247:                DOR &
248:                std_logic_vector(PC) & std_logic_vector(SP) & std_logic_vector(R) & I & Fp & Ap & F & ACC when Alternate = '0'
249: 	  else IntE_FF2 & IntE_FF1 & IStatus &
250:                DOR(127 downto 112) & DOR(47 downto 0) & DOR(63 downto 48) & DOR(111 downto 64) &
251:                std_logic_vector(PC) & std_logic_vector(SP) & std_logic_vector(R) & I & Fp & Ap & F & ACC;
252: 
253: 	mcode : T80_MCode
254: 		generic map(
255: 			Mode => Mode,
256: 			Flag_C => Flag_C,
257: 			Flag_N => Flag_N,
258: 			Flag_P => Flag_P,
259: 			Flag_X => Flag_X,
260: 			Flag_H => Flag_H,
261: 			Flag_Y => Flag_Y,
262: 			Flag_Z => Flag_Z,
263: 			Flag_S => Flag_S)
264: 		port map(
265: 			IR => IR,
266: 			ISet => ISet,
267: 			MCycle => MCycle,
268: 			F => F,
269: 			NMICycle => NMICycle,
270: 			IntCycle => IntCycle,
271: 			MCycles => MCycles_d,
272: 			TStates => TStates,
273: 			Prefix => Prefix,
274: 			Inc_PC => Inc_PC,
275: 			Inc_WZ => Inc_WZ,
276: 			IncDec_16 => IncDec_16,
277: 			Read_To_Acc => Read_To_Acc,
278: 			Read_To_Reg => Read_To_Reg,
279: 			Set_BusB_To => Set_BusB_To,
280: 			Set_BusA_To => Set_BusA_To,
281: 			ALU_Op => ALU_Op,
282: 			Save_ALU => Save_ALU,
283: 			PreserveC => PreserveC,
284: 			Arith16 => Arith16,
285: 			Set_Addr_To => Set_Addr_To,
286: 			IORQ => IORQ_i,
287: 			Jump => Jump,
288: 			JumpE => JumpE,
289: 			JumpXY => JumpXY,
290: 			Call => Call,
291: 			RstP => RstP,
292: 			LDZ => LDZ,
293: 			LDW => LDW,
294: 			LDSPHL => LDSPHL,
295: 			Special_LD => Special_LD,
296: 			ExchangeDH => ExchangeDH,
297: 			ExchangeRp => ExchangeRp,
298: 			ExchangeAF => ExchangeAF,
299: 			ExchangeRS => ExchangeRS,
300: 			I_DJNZ => I_DJNZ,
301: 			I_CPL => I_CPL,
302: 			I_CCF => I_CCF,
303: 			I_SCF => I_SCF,
304: 			I_RETN => I_RETN,
305: 			I_BT => I_BT,
306: 			I_BC => I_BC,
307: 			I_BTR => I_BTR,
308: 			I_RLD => I_RLD,
309: 			I_RRD => I_RRD,
310: 			I_INRC => I_INRC,
311: 			SetDI => SetDI,
312: 			SetEI => SetEI,
313: 			IMode => IMode,
314: 			Halt => Halt,
315: 			NoRead => NoRead,
316: 			Write => Write);
317: 
318: 	alu : T80_ALU
319: 		generic map(
320: 			Mode => Mode,
321: 			Flag_C => Flag_C,
322: 			Flag_N => Flag_N,
323: 			Flag_P => Flag_P,
324: 			Flag_X => Flag_X,
325: 			Flag_H => Flag_H,
326: 			Flag_Y => Flag_Y,
327: 			Flag_Z => Flag_Z,
328: 			Flag_S => Flag_S)
329: 		port map(
330: 			Arith16 => Arith16_r,
331: 			Z16 => Z16_r,
332: 			ALU_Op => ALU_Op_r,
333: 			IR => IR(5 downto 0),
334: 			ISet => ISet,
335: 			BusA => BusA,
336: 			BusB => BusB,
337: 			F_In => F,
338: 			Q => ALU_Q,
339: 			F_Out => F_Out);
340: 
341: 	ClkEn <= CEN and not BusAck;
342: 
343: 	T_Res <= '1' when TState = unsigned(TStates) else '0';
344: 
345: 	NextIs_XY_Fetch <= '1' when XY_State /= "00" and XY_Ind = '0' and
346: 							((Set_Addr_To = aXY) or
347: 							(MCycle = "001" and IR = "11001011") or
348: 							(MCycle = "001" and IR = "00110110")) else '0';
349: 
350: 	Save_Mux <= BusB when ExchangeRp = '1' else
351: 		DI_Reg when Save_ALU_r = '0' else
352: 		ALU_Q;
353: 
354: 	process (RESET_n, CLK_n)
355: 	begin
356: 		if RESET_n = '0' then
357: 			PC <= (others => '0');  -- Program Counter
358: 			A <= (others => '0');
359: 			TmpAddr <= (others => '0');
360: 			IR <= "00000000";
361: 			ISet <= "00";
362: 			XY_State <= "00";
363: 			IStatus <= "00";
364: 			MCycles <= "000";
365: 			DO <= "00000000";
366: 
367: 			ACC <= (others => '1');
368: 			F <= (others => '1');
369: 			Ap <= (others => '1');
370: 			Fp <= (others => '1');
371: 			I <= (others => '0');
372: 			R <= (others => '0');
373: 			SP <= (others => '1');
374: 			Alternate <= '0';
375: 
376: 			Read_To_Reg_r <= "00000";
377: 			F <= (others => '1');
378: 			Arith16_r <= '0';
379: 			BTR_r <= '0';
380: 			Z16_r <= '0';
381: 			ALU_Op_r <= "0000";
382: 			Save_ALU_r <= '0';
383: 			PreserveC_r <= '0';
384: 			XY_Ind <= '0';
385: 
386: 		elsif CLK_n'event and CLK_n = '1' then
387: 
388: 			if ClkEn = '1' then
389: 
390: 			ALU_Op_r <= "0000";
391: 			Save_ALU_r <= '0';
392: 			Read_To_Reg_r <= "00000";
393: 
394: 			MCycles <= MCycles_d;
395: 
396: 			if IMode /= "11" then
397: 				IStatus <= IMode;
398: 			end if;
399: 
400: 			Arith16_r <= Arith16;
401: 			PreserveC_r <= PreserveC;
402: 			if ISet = "10" and ALU_OP(2) = '0' and ALU_OP(0) = '1' and MCycle = "011" then
403: 				Z16_r <= '1';
404: 			else
405: 				Z16_r <= '0';
406: 			end if;
407: 
408: 			if MCycle  = "001" and TState(2) = '0' then
409: 			-- MCycle = 1 and TState = 1, 2, or 3
410: 
411: 				if TState = 2 and Wait_n = '1' then
412: 					if Mode < 2 then
413: 						A(7 downto 0) <= std_logic_vector(R);
414: 						A(15 downto 8) <= I;
415: 						R(6 downto 0) <= R(6 downto 0) + 1;
416: 					end if;
417: 
418: 					if Jump = '0' and Call = '0' and NMICycle = '0' and IntCycle = '0' and not (Halt_FF = '1' or Halt = '1') then
419: 						PC <= PC + 1;
420: 					end if;
421: 
422: 					if IntCycle = '1' and IStatus = "01" then
423: 						IR <= "11111111";
424: 					elsif Halt_FF = '1' or (IntCycle = '1' and IStatus = "10") or NMICycle = '1' then
425: 						IR <= "00000000";
426: 					else
427: 						IR <= DInst;
428: 					end if;
429: 
430: 					ISet <= "00";
431: 					if Prefix /= "00" then
432: 						if Prefix = "11" then
433: 							if IR(5) = '1' then
434: 								XY_State <= "10";
435: 							else
436: 								XY_State <= "01";
437: 							end if;
438: 						else
439: 							if Prefix = "10" then
440: 								XY_State <= "00";
441: 								XY_Ind <= '0';
442: 							end if;
443: 							ISet <= Prefix;
444: 						end if;
445: 					else
446: 						XY_State <= "00";
447: 						XY_Ind <= '0';
448: 					end if;
449: 				end if;
450: 
451: 			else
452: 			-- either (MCycle > 1) OR (MCycle = 1 AND TState > 3)
453: 
454: 				if MCycle = "110" then
455: 					XY_Ind <= '1';
456: 					if Prefix = "01" then
457: 						ISet <= "01";
458: 					end if;
459: 				end if;
460: 
461: 				if T_Res = '1' then
462: 					BTR_r <= (I_BT or I_BC or I_BTR) and not No_BTR;
463: 					if Jump = '1' then
464: 						A(15 downto 8) <= DI_Reg;
465: 						A(7 downto 0) <= TmpAddr(7 downto 0);
466: 						PC(15 downto 8) <= unsigned(DI_Reg);
467: 						PC(7 downto 0) <= unsigned(TmpAddr(7 downto 0));
468: 					elsif JumpXY = '1' then
469: 						A <= RegBusC;
470: 						PC <= unsigned(RegBusC);
471: 					elsif Call = '1' or RstP = '1' then
472: 						A <= TmpAddr;
473: 						PC <= unsigned(TmpAddr);
474: 					elsif MCycle = MCycles and NMICycle = '1' then
475: 						A <= "0000000001100110";
476: 						PC <= "0000000001100110";
477: 					elsif MCycle = "011" and IntCycle = '1' and IStatus = "10" then
478: 						A(15 downto 8) <= I;
479: 						A(7 downto 0) <= TmpAddr(7 downto 0);
480: 						PC(15 downto 8) <= unsigned(I);
481: 						PC(7 downto 0) <= unsigned(TmpAddr(7 downto 0));
482: 					else
483: 						case Set_Addr_To is
484: 						when aXY =>
485: 							if XY_State = "00" then
486: 								A <= RegBusC;
487: 							else
488: 								if NextIs_XY_Fetch = '1' then
489: 									A <= std_logic_vector(PC);
490: 								else
491: 									A <= TmpAddr;
492: 								end if;
493: 							end if;
494: 						when aIOA =>
495: 							if Mode = 3 then
496: 								-- Memory map I/O on GBZ80
497: 								A(15 downto 8) <= (others => '1');
498: 							elsif Mode = 2 then
499: 								-- Duplicate I/O address on 8080
500: 								A(15 downto 8) <= DI_Reg;
501: 							else
502: 								A(15 downto 8) <= ACC;
503: 							end if;
504: 							A(7 downto 0) <= DI_Reg;
505: 						when aSP =>
506: 							A <= std_logic_vector(SP);
507: 						when aBC =>
508: 							if Mode = 3 and IORQ_i = '1' then
509: 								-- Memory map I/O on GBZ80
510: 								A(15 downto 8) <= (others => '1');
511: 								A(7 downto 0) <= RegBusC(7 downto 0);
512: 							else
513: 								A <= RegBusC;
514: 							end if;
515: 						when aDE =>
516: 							A <= RegBusC;
517: 						when aZI =>
518: 							if Inc_WZ = '1' then
519: 								A <= std_logic_vector(unsigned(TmpAddr) + 1);
520: 							else
521: 								A(15 downto 8) <= DI_Reg;
522: 								A(7 downto 0) <= TmpAddr(7 downto 0);
523: 							end if;
524: 						when others =>
525: 							A <= std_logic_vector(PC);
526: 						end case;
527: 					end if;
528: 
529: 					Save_ALU_r <= Save_ALU;
530: 					ALU_Op_r <= ALU_Op;
531: 
532: 					if I_CPL = '1' then
533: 						-- CPL
534: 						ACC <= not ACC;
535: 						F(Flag_Y) <= not ACC(5);
536: 						F(Flag_H) <= '1';
537: 						F(Flag_X) <= not ACC(3);
538: 						F(Flag_N) <= '1';
539: 					end if;
540: 					if I_CCF = '1' then
541: 						-- CCF
542: 						F(Flag_C) <= not F(Flag_C);
543: 						F(Flag_Y) <= ACC(5);
544: 						F(Flag_H) <= F(Flag_C);
545: 						F(Flag_X) <= ACC(3);
546: 						F(Flag_N) <= '0';
547: 					end if;
548: 					if I_SCF = '1' then
549: 						-- SCF
550: 						F(Flag_C) <= '1';
551: 						F(Flag_Y) <= ACC(5);
552: 						F(Flag_H) <= '0';
553: 						F(Flag_X) <= ACC(3);
554: 						F(Flag_N) <= '0';
555: 					end if;
556: 				end if;
557: 
558: 				if TState = 2 and Wait_n = '1' then
559: 					if ISet = "01" and MCycle = "111" then
560: 						IR <= DInst;
561: 					end if;
562: 					if JumpE = '1' then
563: 						PC <= unsigned(signed(PC) + signed(DI_Reg));
564: 					elsif Inc_PC = '1' then
565: 						PC <= PC + 1;
566: 					end if;
567: 					if BTR_r = '1' then
568: 						PC <= PC - 2;
569: 					end if;
570: 					if RstP = '1' then
571: 						TmpAddr <= (others =>'0');
572: 						TmpAddr(5 downto 3) <= IR(5 downto 3);
573: 					end if;
574: 				end if;
575: 				if TState = 3 and MCycle = "110" then
576: 					TmpAddr <= std_logic_vector(signed(RegBusC) + signed(DI_Reg));
577: 				end if;
578: 
579: 				if (TState = 2 and Wait_n = '1') or (TState = 4 and MCycle = "001") then
580: 					if IncDec_16(2 downto 0) = "111" then
581: 						if IncDec_16(3) = '1' then
582: 							SP <= SP - 1;
583: 						else
584: 							SP <= SP + 1;
585: 						end if;
586: 					end if;
587: 				end if;
588: 
589: 				if LDSPHL = '1' then
590: 					SP <= unsigned(RegBusC);
591: 				end if;
592: 				if ExchangeAF = '1' then
593: 					Ap <= ACC;
594: 					ACC <= Ap;
595: 					Fp <= F;
596: 					F <= Fp;
597: 				end if;
598: 				if ExchangeRS = '1' then
599: 					Alternate <= not Alternate;
600: 				end if;
601: 			end if;
602: 
603: 			if TState = 3 then
604: 				if LDZ = '1' then
605: 					TmpAddr(7 downto 0) <= DI_Reg;
606: 				end if;
607: 				if LDW = '1' then
608: 					TmpAddr(15 downto 8) <= DI_Reg;
609: 				end if;
610: 
611: 				if Special_LD(2) = '1' then
612: 					case Special_LD(1 downto 0) is
613: 					when "00" =>
614: 						ACC <= I;
615: 						F(Flag_P) <= IntE_FF2;
616: 					when "01" =>
617: 						ACC <= std_logic_vector(R);
618: 						F(Flag_P) <= IntE_FF2;
619: 					when "10" =>
620: 						I <= ACC;
621: 					when others =>
622: 						R <= unsigned(ACC);
623: 					end case;
624: 				end if;
625: 			end if;
626: 
627: 			if (I_DJNZ = '0' and Save_ALU_r = '1') or ALU_Op_r = "1001" then
628: 				if Mode = 3 then
629: 					F(6) <= F_Out(6);
630: 					F(5) <= F_Out(5);
631: 					F(7) <= F_Out(7);
632: 					if PreserveC_r = '0' then
633: 						F(4) <= F_Out(4);
634: 					end if;
635: 				else
636: 					F(7 downto 1) <= F_Out(7 downto 1);
637: 					if PreserveC_r = '0' then
638: 						F(Flag_C) <= F_Out(0);
639: 					end if;
640: 				end if;
641: 			end if;
642: 			if T_Res = '1' and I_INRC = '1' then
643: 				F(Flag_H) <= '0';
644: 				F(Flag_N) <= '0';
645: 				if DI_Reg(7 downto 0) = "00000000" then
646: 					F(Flag_Z) <= '1';
647: 				else
648: 					F(Flag_Z) <= '0';
649: 				end if;
650: 				F(Flag_S) <= DI_Reg(7);
651: 				F(Flag_P) <= not (DI_Reg(0) xor DI_Reg(1) xor DI_Reg(2) xor DI_Reg(3) xor
652: 					DI_Reg(4) xor DI_Reg(5) xor DI_Reg(6) xor DI_Reg(7));
653: 			end if;
654: 
655: 			if TState = 1 and Auto_Wait_t1 = '0' then
656: 				DO <= BusB;
657: 				if I_RLD = '1' then
658: 					DO(3 downto 0) <= BusA(3 downto 0);
659: 					DO(7 downto 4) <= BusB(3 downto 0);
660: 				end if;
661: 				if I_RRD = '1' then
662: 					DO(3 downto 0) <= BusB(7 downto 4);
663: 					DO(7 downto 4) <= BusA(3 downto 0);
664: 				end if;
665: 			end if;
666: 
667: 			if T_Res = '1' then
668: 				Read_To_Reg_r(3 downto 0) <= Set_BusA_To;
669: 				Read_To_Reg_r(4) <= Read_To_Reg;
670: 				if Read_To_Acc = '1' then
671: 					Read_To_Reg_r(3 downto 0) <= "0111";
672: 					Read_To_Reg_r(4) <= '1';
673: 				end if;
674: 			end if;
675: 
676: 			if TState = 1 and I_BT = '1' then
677: 				F(Flag_X) <= ALU_Q(3);
678: 				F(Flag_Y) <= ALU_Q(1);
679: 				F(Flag_H) <= '0';
680: 				F(Flag_N) <= '0';
681: 			end if;
682: 			if I_BC = '1' or I_BT = '1' then
683: 				F(Flag_P) <= IncDecZ;
684: 			end if;
685: 
686: 			if (TState = 1 and Save_ALU_r = '0' and Auto_Wait_t1 = '0') or
687: 				(Save_ALU_r = '1' and ALU_OP_r /= "0111") then
688: 				case Read_To_Reg_r is
689: 				when "10111" =>
690: 					ACC <= Save_Mux;
691: 				when "10110" =>
692: 					DO <= Save_Mux;
693: 				when "11000" =>
694: 					SP(7 downto 0) <= unsigned(Save_Mux);
695: 				when "11001" =>
696: 					SP(15 downto 8) <= unsigned(Save_Mux);
697: 				when "11011" =>
698: 					F <= Save_Mux;
699: 				when others =>
700: 				end case;
701: 			end if;
702: 
703: 		end if;
704: 
705: 		end if;
706: 
707: 	end process;
708: 
709: ---------------------------------------------------------------------------
710: --
711: -- BC('), DE('), HL('), IX and IY
712: --
713: ---------------------------------------------------------------------------
714: 	process (CLK_n)
715: 	begin
716: 		if CLK_n'event and CLK_n = '1' then
717: 			if ClkEn = '1' then
718: 				-- Bus A / Write
719: 				RegAddrA_r <= Alternate & Set_BusA_To(2 downto 1);
720: 				if XY_Ind = '0' and XY_State /= "00" and Set_BusA_To(2 downto 1) = "10" then
721: 					RegAddrA_r <= XY_State(1) & "11";
722: 				end if;
723: 
724: 				-- Bus B
725: 				RegAddrB_r <= Alternate & Set_BusB_To(2 downto 1);
726: 				if XY_Ind = '0' and XY_State /= "00" and Set_BusB_To(2 downto 1) = "10" then
727: 					RegAddrB_r <= XY_State(1) & "11";
728: 				end if;
729: 
730: 				-- Address from register
731: 				RegAddrC <= Alternate & Set_Addr_To(1 downto 0);
732: 				-- Jump (HL), LD SP,HL
733: 				if (JumpXY = '1' or LDSPHL = '1') then
734: 					RegAddrC <= Alternate & "10";
735: 				end if;
736: 				if ((JumpXY = '1' or LDSPHL = '1') and XY_State /= "00") or (MCycle = "110") then
737: 					RegAddrC <= XY_State(1) & "11";
738: 				end if;
739: 
740: 				if I_DJNZ = '1' and Save_ALU_r = '1' and Mode < 2 then
741: 					IncDecZ <= F_Out(Flag_Z);
742: 				end if;
743: 				if (TState = 2 or (TState = 3 and MCycle = "001")) and IncDec_16(2 downto 0) = "100" then
744: 					if ID16 = 0 then
745: 						IncDecZ <= '0';
746: 					else
747: 						IncDecZ <= '1';
748: 					end if;
749: 				end if;
750: 
751: 				RegBusA_r <= RegBusA;
752: 			end if;
753: 		end if;
754: 	end process;
755: 
756: 	RegAddrA <=
757: 			-- 16 bit increment/decrement
758: 			Alternate & IncDec_16(1 downto 0) when (TState = 2 or
759: 				(TState = 3 and MCycle = "001" and IncDec_16(2) = '1')) and XY_State = "00" else
760: 			XY_State(1) & "11" when (TState = 2 or
761: 				(TState = 3 and MCycle = "001" and IncDec_16(2) = '1')) and IncDec_16(1 downto 0) = "10" else
762: 			-- EX HL,DL
763: 			Alternate & "10" when ExchangeDH = '1' and TState = 3 else
764: 			Alternate & "01" when ExchangeDH = '1' and TState = 4 else
765: 			-- Bus A / Write
766: 			RegAddrA_r;
767: 
768: 	RegAddrB <=
769: 			-- EX HL,DL
770: 			Alternate & "01" when ExchangeDH = '1' and TState = 3 else
771: 			-- Bus B
772: 			RegAddrB_r;
773: 
774: 	ID16 <= signed(RegBusA) - 1 when IncDec_16(3) = '1' else
775: 			signed(RegBusA) + 1;
776: 
777: 	process (Save_ALU_r, Auto_Wait_t1, ALU_OP_r, Read_To_Reg_r,
778: 			ExchangeDH, IncDec_16, MCycle, TState, Wait_n)
779: 	begin
780: 		RegWEH <= '0';
781: 		RegWEL <= '0';
782: 		if (TState = 1 and Save_ALU_r = '0' and Auto_Wait_t1 = '0') or
783: 			(Save_ALU_r = '1' and ALU_OP_r /= "0111") then
784: 			case Read_To_Reg_r is
785: 			when "10000" | "10001" | "10010" | "10011" | "10100" | "10101" =>
786: 				RegWEH <= not Read_To_Reg_r(0);
787: 				RegWEL <= Read_To_Reg_r(0);
788: 			when others =>
789: 			end case;
790: 		end if;
791: 
792: 		if ExchangeDH = '1' and (TState = 3 or TState = 4) then
793: 			RegWEH <= '1';
794: 			RegWEL <= '1';
795: 		end if;
796: 
797: 		if IncDec_16(2) = '1' and ((TState = 2 and Wait_n = '1' and MCycle /= "001") or (TState = 3 and MCycle = "001")) then
798: 			case IncDec_16(1 downto 0) is
799: 			when "00" | "01" | "10" =>
800: 				RegWEH <= '1';
801: 				RegWEL <= '1';
802: 			when others =>
803: 			end case;
804: 		end if;
805: 	end process;
806: 
807: 	process (Save_Mux, RegBusB, RegBusA_r, ID16,
808: 			ExchangeDH, IncDec_16, MCycle, TState, Wait_n)
809: 	begin
810: 		RegDIH <= Save_Mux;
811: 		RegDIL <= Save_Mux;
812: 
813: 		if ExchangeDH = '1' and TState = 3 then
814: 			RegDIH <= RegBusB(15 downto 8);
815: 			RegDIL <= RegBusB(7 downto 0);
816: 		end if;
817: 		if ExchangeDH = '1' and TState = 4 then
818: 			RegDIH <= RegBusA_r(15 downto 8);
819: 			RegDIL <= RegBusA_r(7 downto 0);
820: 		end if;
821: 
822: 		if IncDec_16(2) = '1' and ((TState = 2 and MCycle /= "001") or (TState = 3 and MCycle = "001")) then
823: 			RegDIH <= std_logic_vector(ID16(15 downto 8));
824: 			RegDIL <= std_logic_vector(ID16(7 downto 0));
825: 		end if;
826: 	end process;
827: 
828: 	Regs : T80_Reg
829: 		port map(
830: 			Clk => CLK_n,
831: 			CEN => ClkEn,
832: 			WEH => RegWEH,
833: 			WEL => RegWEL,
834: 			AddrA => RegAddrA,
835: 			AddrB => RegAddrB,
836: 			AddrC => RegAddrC,
837: 			DIH => RegDIH,
838: 			DIL => RegDIL,
839: 			DOAH => RegBusA(15 downto 8),
840: 			DOAL => RegBusA(7 downto 0),
841: 			DOBH => RegBusB(15 downto 8),
842: 			DOBL => RegBusB(7 downto 0),
843: 			DOCH => RegBusC(15 downto 8),
844: 			DOCL => RegBusC(7 downto 0),
845: 			DOR  => DOR);
846: 
847: ---------------------------------------------------------------------------
848: --
849: -- Buses
850: --
851: ---------------------------------------------------------------------------
852: 	process (CLK_n)
853: 	begin
854: 		if CLK_n'event and CLK_n = '1' then
855: 			if ClkEn = '1' then
856: 			case Set_BusB_To is
857: 			when "0111" =>
858: 				BusB <= ACC;
859: 			when "0000" | "0001" | "0010" | "0011" | "0100" | "0101" =>
860: 				if Set_BusB_To(0) = '1' then
861: 					BusB <= RegBusB(7 downto 0);
862: 				else
863: 					BusB <= RegBusB(15 downto 8);
864: 				end if;
865: 			when "0110" =>
866: 				BusB <= DI_Reg;
867: 			when "1000" =>
868: 				BusB <= std_logic_vector(SP(7 downto 0));
869: 			when "1001" =>
870: 				BusB <= std_logic_vector(SP(15 downto 8));
871: 			when "1010" =>
872: 				BusB <= "00000001";
873: 			when "1011" =>
874: 				BusB <= F;
875: 			when "1100" =>
876: 				BusB <= std_logic_vector(PC(7 downto 0));
877: 			when "1101" =>
878: 				BusB <= std_logic_vector(PC(15 downto 8));
879: 			when "1110" =>
880: 				BusB <= "00000000";
881: 			when others =>
882: 				BusB <= "--------";
883: 			end case;
884: 
885: 			case Set_BusA_To is
886: 			when "0111" =>
887: 				BusA <= ACC;
888: 			when "0000" | "0001" | "0010" | "0011" | "0100" | "0101" =>
889: 				if Set_BusA_To(0) = '1' then
890: 					BusA <= RegBusA(7 downto 0);
891: 				else
892: 					BusA <= RegBusA(15 downto 8);
893: 				end if;
894: 			when "0110" =>
895: 				BusA <= DI_Reg;
896: 			when "1000" =>
897: 				BusA <= std_logic_vector(SP(7 downto 0));
898: 			when "1001" =>
899: 				BusA <= std_logic_vector(SP(15 downto 8));
900: 			when "1010" =>
901: 				BusA <= "00000000";
902: 			when others =>
903: 				BusB <= "--------";
904: 			end case;
905: 			end if;
906: 		end if;
907: 	end process;
908: 
909: ---------------------------------------------------------------------------
910: --
911: -- Generate external control signals
912: --
913: ---------------------------------------------------------------------------
914: 	process (RESET_n,CLK_n)
915: 	begin
916: 		if RESET_n = '0' then
917: 			RFSH_n <= '1';
918: 		elsif CLK_n'event and CLK_n = '1' then
919: 			if CEN = '1' then
920: 			if MCycle = "001" and ((TState = 2  and Wait_n = '1') or TState = 3) then
921: 				RFSH_n <= '0';
922: 			else
923: 				RFSH_n <= '1';
924: 			end if;
925: 			end if;
926: 		end if;
927: 	end process;
928: 
929: 	MC <= std_logic_vector(MCycle);
930: 	TS <= std_logic_vector(TState);
931: 	DI_Reg <= DI;
932: 	HALT_n <= not Halt_FF;
933: 	BUSAK_n <= not BusAck;
934: 	IntCycle_n <= not IntCycle;
935: 	IntE <= IntE_FF1;
936: 	IORQ <= IORQ_i;
937: 	Stop <= I_DJNZ;
938: 
939: -------------------------------------------------------------------------
940: --
941: -- Syncronise inputs
942: --
943: -------------------------------------------------------------------------
944: 	process (RESET_n, CLK_n)
945: 		variable OldNMI_n : std_logic;
946: 	begin
947: 		if RESET_n = '0' then
948: 			BusReq_s <= '0';
949: 			INT_s <= '0';
950: 			NMI_s <= '0';
951: 			OldNMI_n := '0';
952: 		elsif CLK_n'event and CLK_n = '1' then
953: 			if CEN = '1' then
954: 			BusReq_s <= not BUSRQ_n;
955: 			INT_s <= not INT_n;
956: 			if NMICycle = '1' then
957: 				NMI_s <= '0';
958: 			elsif NMI_n = '0' and OldNMI_n = '1' then
959: 				NMI_s <= '1';
960: 			end if;
961: 			OldNMI_n := NMI_n;
962: 			end if;
963: 		end if;
964: 	end process;
965: 
966: -------------------------------------------------------------------------
967: --
968: -- Main state machine
969: --
970: -------------------------------------------------------------------------
971: 	process (RESET_n, CLK_n)
972: 	begin
973: 		if RESET_n = '0' then
974: 			MCycle <= "001";
975: 			TState <= "000";
976: 			Pre_XY_F_M <= "000";
977: 			Halt_FF <= '0';
978: 			BusAck <= '0';
979: 			NMICycle <= '0';
980: 			IntCycle <= '0';
981: 			IntE_FF1 <= '0';
982: 			IntE_FF2 <= '0';
983: 			No_BTR <= '0';
984: 			Auto_Wait_t1 <= '0';
985: 			Auto_Wait_t2 <= '0';
986: 			M1_n <= '1';
987: 		elsif CLK_n'event and CLK_n = '1' then
988: 			if CEN = '1' then
989: 			if T_Res = '1' then
990: 				Auto_Wait_t1 <= '0';
991: 			else
992: 				Auto_Wait_t1 <= Auto_Wait or IORQ_i;
993: 			end if;
994: 			Auto_Wait_t2 <= Auto_Wait_t1;
995: 			No_BTR <= (I_BT and (not IR(4) or not F(Flag_P))) or
996: 					(I_BC and (not IR(4) or F(Flag_Z) or not F(Flag_P))) or
997: 					(I_BTR and (not IR(4) or F(Flag_Z)));
998: 			if TState = 2 then
999: 				if SetEI = '1' then
1000: 					IntE_FF1 <= '1';
1001: 					IntE_FF2 <= '1';
1002: 				end if;
1003: 				if I_RETN = '1' then
1004: 					IntE_FF1 <= IntE_FF2;
1005: 				end if;
1006: 			end if;
1007: 			if TState = 3 then
1008: 				if SetDI = '1' then
1009: 					IntE_FF1 <= '0';
1010: 					IntE_FF2 <= '0';
1011: 				end if;
1012: 			end if;
1013: 			if IntCycle = '1' or NMICycle = '1' then
1014: 				Halt_FF <= '0';
1015: 			end if;
1016: 			if MCycle = "001" and TState = 2 and Wait_n = '1' then
1017: 				M1_n <= '1';
1018: 			end if;
1019: 			if BusReq_s = '1' and BusAck = '1' then
1020: 			else
1021: 				BusAck <= '0';
1022: 				if TState = 2 and Wait_n = '0' then
1023: 				elsif T_Res = '1' then
1024: 					if Halt = '1' then
1025: 						Halt_FF <= '1';
1026: 					end if;
1027: 					if BusReq_s = '1' then
1028: 						BusAck <= '1';
1029: 					else
1030: 						TState <= "001";
1031: 						if NextIs_XY_Fetch = '1' then
1032: 							MCycle <= "110";
1033: 							Pre_XY_F_M <= MCycle;
1034: 							if IR = "00110110" and Mode = 0 then
1035: 								Pre_XY_F_M <= "010";
1036: 							end if;
1037: 						elsif (MCycle = "111") or
1038: 							(MCycle = "110" and Mode = 1 and ISet /= "01") then
1039: 							MCycle <= std_logic_vector(unsigned(Pre_XY_F_M) + 1);
1040: 						elsif (MCycle = MCycles) or
1041: 							No_BTR = '1' or
1042: 							(MCycle = "010" and I_DJNZ = '1' and IncDecZ = '1') then
1043: 							M1_n <= '0';
1044: 							MCycle <= "001";
1045: 							IntCycle <= '0';
1046: 							NMICycle <= '0';
1047: 							if NMI_s = '1' and Prefix = "00" then
1048: 								NMICycle <= '1';
1049: 								IntE_FF1 <= '0';
1050: 							elsif (IntE_FF1 = '1' and INT_s = '1') and Prefix = "00" and SetEI = '0' then
1051: 								IntCycle <= '1';
1052: 								IntE_FF1 <= '0';
1053: 								IntE_FF2 <= '0';
1054: 							end if;
1055: 						else
1056: 							MCycle <= std_logic_vector(unsigned(MCycle) + 1);
1057: 						end if;
1058: 					end if;
1059: 				else
1060: 					if (Auto_Wait = '1' and Auto_Wait_t2 = '0') nor
1061: 						(IOWait = 1 and IORQ_i = '1' and Auto_Wait_t1 = '0') then
1062: 						TState <= TState + 1;
1063: 					end if;
1064: 				end if;
1065: 			end if;
1066: 			if TState = 0 then
1067: 				M1_n <= '0';
1068: 			end if;
1069: 			end if;
1070: 		end if;
1071: 	end process;
1072: 
1073: 	process (IntCycle, NMICycle, MCycle)
1074: 	begin
1075: 		Auto_Wait <= '0';
1076: 		if IntCycle = '1' or NMICycle = '1' then
1077: 			if MCycle = "001" then
1078: 				Auto_Wait <= '1';
1079: 			end if;
1080: 		end if;
1081: 	end process;
1082: 
1083: end;

(End of file - total 1083 lines)
</content>
```

---

## Assistant (Plan · Claude Opus 4.8 · 8.1s)

Now I have a deep understanding of the datapath. Let me check the register file and the JumpXY mechanism, and verify the `RegBusC`/`Set_Addr_To` behavior, and the existing `JP (HL)` since the NEXT ends with `jp (hl)` analog.

Let me re-examine the NEXT semantics precisely:

```
ex de,hl      ; HL=IP, DE=old W
ld e,(hl)     ; read low byte of cell pointed by IP into E
inc hl        ; IP++
ld d,(hl)     ; read high byte into D
inc hl        ; IP++
ex de,hl      ; HL = cell value (W), DE = IP (advanced by 2)
jp (hl)       ; jump to W
```

So the net effect: read a 16-bit word from memory at address IP (DE), advance IP by 2, and jump to PC = that word. Let me check the register encoding and the `JumpXY`/`RegBusC` selection more carefully, plus how `aDE`/`aZI` reads work and `LDZ`/`LDW`/`TmpAddr`.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_Reg.vhd"
}
```

**Output:**
```
<path>/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_Reg.vhd</path>
<type>file</type>
<content>
1: --
2: -- T80 Registers, technology independent
3: --
4: -- Version : 0244
5: --
6: -- Copyright (c) 2002 Daniel Wallner (jesus@opencores.org)
7: --
8: -- All rights reserved
9: --
10: -- Redistribution and use in source and synthezised forms, with or without
11: -- modification, are permitted provided that the following conditions are met:
12: --
13: -- Redistributions of source code must retain the above copyright notice,
14: -- this list of conditions and the following disclaimer.
15: --
16: -- Redistributions in synthesized form must reproduce the above copyright
17: -- notice, this list of conditions and the following disclaimer in the
18: -- documentation and/or other materials provided with the distribution.
19: --
20: -- Neither the name of the author nor the names of other contributors may
21: -- be used to endorse or promote products derived from this software without
22: -- specific prior written permission.
23: --
24: -- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
25: -- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
26: -- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
27: -- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
28: -- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
29: -- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
30: -- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
31: -- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
32: -- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
33: -- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
34: -- POSSIBILITY OF SUCH DAMAGE.
35: --
36: -- Please report bugs to the author, but before you do so, please
37: -- make sure that this is not a derivative work and that
38: -- you have the latest version of this file.
39: --
40: -- The latest version of this file can be found at:
41: --	http://www.opencores.org/cvsweb.shtml/t51/
42: --
43: -- Limitations :
44: --
45: -- File history :
46: --
47: --	0242 : Initial release
48: --
49: --	0244 : Changed to single register file
50: --
51: 
52: library IEEE;
53: use IEEE.std_logic_1164.all;
54: use IEEE.numeric_std.all;
55: 
56: entity T80_Reg is
57: 	port(
58: 		Clk			: in std_logic;
59: 		CEN			: in std_logic;
60: 		WEH			: in std_logic;
61: 		WEL			: in std_logic;
62: 		AddrA		: in std_logic_vector(2 downto 0);
63: 		AddrB		: in std_logic_vector(2 downto 0);
64: 		AddrC		: in std_logic_vector(2 downto 0);
65: 		DIH			: in std_logic_vector(7 downto 0);
66: 		DIL			: in std_logic_vector(7 downto 0);
67: 		DOAH		: out std_logic_vector(7 downto 0);
68: 		DOAL		: out std_logic_vector(7 downto 0);
69: 		DOBH		: out std_logic_vector(7 downto 0);
70: 		DOBL		: out std_logic_vector(7 downto 0);
71: 		DOCH		: out std_logic_vector(7 downto 0);
72: 		DOCL		: out std_logic_vector(7 downto 0);
73: 		DOR		: out std_logic_vector(127 downto 0)
74: 	);
75: end T80_Reg;
76: 
77: architecture rtl of T80_Reg is
78: 
79: 	type Register_Image is array (natural range <>) of std_logic_vector(7 downto 0);
80: 	signal	RegsH	: Register_Image(0 to 7);
81: 	signal	RegsL	: Register_Image(0 to 7);
82: 
83: begin
84: 
85: 	process (Clk)
86: 	begin
87: 		if Clk'event and Clk = '1' then
88: 			if CEN = '1' then
89: 				if WEH = '1' then
90: 					RegsH(to_integer(unsigned(AddrA))) <= DIH;
91: 				end if;
92: 				if WEL = '1' then
93: 					RegsL(to_integer(unsigned(AddrA))) <= DIL;
94: 				end if;
95: 			end if;
96: 		end if;
97: 	end process;
98: 
99: 	DOAH <= RegsH(to_integer(unsigned(AddrA)));
100: 	DOAL <= RegsL(to_integer(unsigned(AddrA)));
101: 	DOBH <= RegsH(to_integer(unsigned(AddrB)));
102: 	DOBL <= RegsL(to_integer(unsigned(AddrB)));
103: 	DOCH <= RegsH(to_integer(unsigned(AddrC)));
104: 	DOCL <= RegsL(to_integer(unsigned(AddrC)));
105: 	DOR  <= RegsH(7) & RegsL(7) & RegsH(6) & RegsL(6) & RegsH(5) & RegsL(5) & RegsH(4) & RegsL(4) &
106:                 RegsH(3) & RegsL(3) & RegsH(2) & RegsL(2) & RegsH(1) & RegsL(1) & RegsH(0) & RegsL(0);
107: 
108: end;

(End of file - total 108 lines)
</content>
```

---

## Assistant (Plan · Claude Opus 4.8 · 10.7s)

Now I understand the register file. Register addresses (within a bank, `Alternate` is bit 2): index 0=BC, 1=DE, 2=HL, 3=SP. The `Set_BusA_To`/`Set_BusB_To`/`Set_Addr_To` use a 2-bit pair index. Let me confirm the register pair encoding used by `Set_BusA_To` codes:

- `"000"/"001"` = B/C, `"010"/"011"` = D/E, `"100"/"101"` = H/L, `"1000"/"1001"` = SP(L)/SP(M).

So pair index 1 = DE, pair index 2 = HL. `Set_Addr_To` `aDE="001"`, `aHL`... there's no aHL but aXY="010" maps via RegAddrC to register pair index 2 (HL). Good.

Now let me look at how `LD HL,(nn)` works (the closest analog: read 16 bits from a memory address into a register pair, using aZI addressing, Inc_WZ). And how `LD dd,(nn)` (ED 4B etc.) works, which I already saw at lines 1533-1563. That's the perfect template — it reads 16 bits from memory at TmpAddr into a register pair.

But for NEXT, the source address is DE (IP), not an immediate nn. And after reading, IP must be incremented by 2, and we must JUMP to the value read (W), like `JP (HL)` does via JumpXY/RegBusC.

Let me check `LD A,(DE)` and `INC ss` interaction, and verify the JumpXY datapath uses `RegBusC`. Let me also examine the T80s.vhd wrapper and T80_Pack.vhd to make sure nothing else needs touching.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_Pack.vhd"
}
```

**Output:**
```
<path>/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_Pack.vhd</path>
<type>file</type>
<content>
1: --
2: -- Z80 compatible microprocessor core
3: --
4: -- Version : 0242
5: --
6: -- Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
7: --
8: -- All rights reserved
9: --
10: -- Redistribution and use in source and synthezised forms, with or without
11: -- modification, are permitted provided that the following conditions are met:
12: --
13: -- Redistributions of source code must retain the above copyright notice,
14: -- this list of conditions and the following disclaimer.
15: --
16: -- Redistributions in synthesized form must reproduce the above copyright
17: -- notice, this list of conditions and the following disclaimer in the
18: -- documentation and/or other materials provided with the distribution.
19: --
20: -- Neither the name of the author nor the names of other contributors may
21: -- be used to endorse or promote products derived from this software without
22: -- specific prior written permission.
23: --
24: -- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
25: -- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
26: -- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
27: -- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
28: -- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
29: -- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
30: -- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
31: -- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
32: -- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
33: -- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
34: -- POSSIBILITY OF SUCH DAMAGE.
35: --
36: -- Please report bugs to the author, but before you do so, please
37: -- make sure that this is not a derivative work and that
38: -- you have the latest version of this file.
39: --
40: -- The latest version of this file can be found at:
41: --	http://www.opencores.org/cvsweb.shtml/t80/
42: --
43: -- Limitations :
44: --
45: -- File history :
46: --
47: 
48: library IEEE;
49: use IEEE.std_logic_1164.all;
50: 
51: package T80_Pack is
52: 
53: 	component T80
54: 	generic(
55: 		Mode : integer := 0;	-- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
56: 		IOWait : integer := 0;	-- 1 => Single cycle I/O, 1 => Std I/O cycle
57: 		Flag_C : integer := 0;
58: 		Flag_N : integer := 1;
59: 		Flag_P : integer := 2;
60: 		Flag_X : integer := 3;
61: 		Flag_H : integer := 4;
62: 		Flag_Y : integer := 5;
63: 		Flag_Z : integer := 6;
64: 		Flag_S : integer := 7
65: 	);
66: 	port(
67: 		RESET_n		: in std_logic;
68: 		CLK_n		: in std_logic;
69: 		CEN			: in std_logic;
70: 		WAIT_n		: in std_logic;
71: 		INT_n		: in std_logic;
72: 		NMI_n		: in std_logic;
73: 		BUSRQ_n		: in std_logic;
74: 		M1_n		: out std_logic;
75: 		IORQ		: out std_logic;
76: 		NoRead		: out std_logic;
77: 		Write		: out std_logic;
78: 		RFSH_n		: out std_logic;
79: 		HALT_n		: out std_logic;
80: 		BUSAK_n		: out std_logic;
81: 		A			: out std_logic_vector(15 downto 0);
82: 		DInst		: in std_logic_vector(7 downto 0);
83: 		DI			: in std_logic_vector(7 downto 0);
84: 		DO			: out std_logic_vector(7 downto 0);
85: 		MC			: out std_logic_vector(2 downto 0);
86: 		TS			: out std_logic_vector(2 downto 0);
87: 		IntCycle_n	: out std_logic;
88: 		IntE		: out std_logic;
89: 		Stop		: out std_logic;
90: 		REG		: out std_logic_vector(211 downto 0) -- IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
91: 	);
92: 	end component;
93: 
94: 	component T80_Reg
95: 	port(
96: 		Clk			: in std_logic;
97: 		CEN			: in std_logic;
98: 		WEH			: in std_logic;
99: 		WEL			: in std_logic;
100: 		AddrA		: in std_logic_vector(2 downto 0);
101: 		AddrB		: in std_logic_vector(2 downto 0);
102: 		AddrC		: in std_logic_vector(2 downto 0);
103: 		DIH			: in std_logic_vector(7 downto 0);
104: 		DIL			: in std_logic_vector(7 downto 0);
105: 		DOAH		: out std_logic_vector(7 downto 0);
106: 		DOAL		: out std_logic_vector(7 downto 0);
107: 		DOBH		: out std_logic_vector(7 downto 0);
108: 		DOBL		: out std_logic_vector(7 downto 0);
109: 		DOCH		: out std_logic_vector(7 downto 0);
110: 		DOCL		: out std_logic_vector(7 downto 0);
111: 		DOR		: out std_logic_vector(127 downto 0)
112: 	);
113: 	end component;
114: 
115: 	component T80_MCode
116: 	generic(
117: 		Mode : integer := 0;
118: 		Flag_C : integer := 0;
119: 		Flag_N : integer := 1;
120: 		Flag_P : integer := 2;
121: 		Flag_X : integer := 3;
122: 		Flag_H : integer := 4;
123: 		Flag_Y : integer := 5;
124: 		Flag_Z : integer := 6;
125: 		Flag_S : integer := 7
126: 	);
127: 	port(
128: 		IR				: in std_logic_vector(7 downto 0);
129: 		ISet			: in std_logic_vector(1 downto 0);
130: 		MCycle			: in std_logic_vector(2 downto 0);
131: 		F				: in std_logic_vector(7 downto 0);
132: 		NMICycle		: in std_logic;
133: 		IntCycle		: in std_logic;
134: 		MCycles			: out std_logic_vector(2 downto 0);
135: 		TStates			: out std_logic_vector(2 downto 0);
136: 		Prefix			: out std_logic_vector(1 downto 0); -- None,BC,ED,DD/FD
137: 		Inc_PC			: out std_logic;
138: 		Inc_WZ			: out std_logic;
139: 		IncDec_16		: out std_logic_vector(3 downto 0); -- BC,DE,HL,SP   0 is inc
140: 		Read_To_Reg		: out std_logic;
141: 		Read_To_Acc		: out std_logic;
142: 		Set_BusA_To	: out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI/DB,A,SP(L),SP(M),0,F
143: 		Set_BusB_To	: out std_logic_vector(3 downto 0); -- B,C,D,E,H,L,DI,A,SP(L),SP(M),1,F,PC(L),PC(M),0
144: 		ALU_Op			: out std_logic_vector(3 downto 0);
145: 			-- ADD, ADC, SUB, SBC, AND, XOR, OR, CP, ROT, BIT, SET, RES, DAA, RLD, RRD, None
146: 		Save_ALU		: out std_logic;
147: 		PreserveC		: out std_logic;
148: 		Arith16			: out std_logic;
149: 		Set_Addr_To		: out std_logic_vector(2 downto 0); -- aNone,aXY,aIOA,aSP,aBC,aDE,aZI
150: 		IORQ			: out std_logic;
151: 		Jump			: out std_logic;
152: 		JumpE			: out std_logic;
153: 		JumpXY			: out std_logic;
154: 		Call			: out std_logic;
155: 		RstP			: out std_logic;
156: 		LDZ				: out std_logic;
157: 		LDW				: out std_logic;
158: 		LDSPHL			: out std_logic;
159: 		Special_LD		: out std_logic_vector(2 downto 0); -- A,I;A,R;I,A;R,A;None
160: 		ExchangeDH		: out std_logic;
161: 		ExchangeRp		: out std_logic;
162: 		ExchangeAF		: out std_logic;
163: 		ExchangeRS		: out std_logic;
164: 		I_DJNZ			: out std_logic;
165: 		I_CPL			: out std_logic;
166: 		I_CCF			: out std_logic;
167: 		I_SCF			: out std_logic;
168: 		I_RETN			: out std_logic;
169: 		I_BT			: out std_logic;
170: 		I_BC			: out std_logic;
171: 		I_BTR			: out std_logic;
172: 		I_RLD			: out std_logic;
173: 		I_RRD			: out std_logic;
174: 		I_INRC			: out std_logic;
175: 		SetDI			: out std_logic;
176: 		SetEI			: out std_logic;
177: 		IMode			: out std_logic_vector(1 downto 0);
178: 		Halt			: out std_logic;
179: 		NoRead			: out std_logic;
180: 		Write			: out std_logic
181: 	);
182: 	end component;
183: 
184: 	component T80_ALU
185: 	generic(
186: 		Mode : integer := 0;
187: 		Flag_C : integer := 0;
188: 		Flag_N : integer := 1;
189: 		Flag_P : integer := 2;
190: 		Flag_X : integer := 3;
191: 		Flag_H : integer := 4;
192: 		Flag_Y : integer := 5;
193: 		Flag_Z : integer := 6;
194: 		Flag_S : integer := 7
195: 	);
196: 	port(
197: 		Arith16		: in std_logic;
198: 		Z16			: in std_logic;
199: 		ALU_Op		: in std_logic_vector(3 downto 0);
200: 		IR			: in std_logic_vector(5 downto 0);
201: 		ISet		: in std_logic_vector(1 downto 0);
202: 		BusA		: in std_logic_vector(7 downto 0);
203: 		BusB		: in std_logic_vector(7 downto 0);
204: 		F_In		: in std_logic_vector(7 downto 0);
205: 		Q			: out std_logic_vector(7 downto 0);
206: 		F_Out		: out std_logic_vector(7 downto 0)
207: 	);
208: 	end component;
209: 
210: end;

(End of file - total 210 lines)
</content>
```

---

## Assistant (Plan · Claude Opus 4.8 · 7.8s)

I now have a complete picture. Let me analyze the exact mechanism needed and identify an unused ED opcode.

Let me look closely at how `JumpXY` and `RegBusC` interact, and how `LD dd,(nn)` reads two bytes — the key reuse pattern. Let me also examine the `Jump` path (lines 463-467) which sets PC from `DI_Reg & TmpAddr`. This is the crucial insight for implementing NEXT.

Let me verify there's no IX/IY complication for ED-set (ISet="10" disables XY_State per lines 439-442). Good.

Now let me think through the cleanest implementation and identify a free opcode. Let me check which ED opcodes are truly NOP/undocumented and free.

**Tool: grep**

**Input:**
```json
{
  "pattern": "when \"1010",
  "path": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd"
}
```

**Output:**
```
Found 4 matches
/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd:
  Line 1597: 			when "10100000" | "10101000" | "10110000" | "10111000" =>

  Line 1628: 			when "10100001" | "10101001" | "10110001" | "10111001" =>

  Line 1823: 			when "10100010" | "10101010" | "10110010" | "10111010" =>

  Line 1852: 			when "10100011" | "10101011" | "10110011" | "10111011" =>

```

---

## Assistant (Plan · Claude Opus 4.8 · 18.7s)

Now let me reason about the implementation precisely. I have all the data I need. Let me verify the `Jump` semantics — at `T_Res` with `Jump='1'`, PC and A are loaded from `DI_Reg(15:8) & TmpAddr(7:0)`. So `DI_Reg` is the most-recently-read byte, and `TmpAddr(7:0)` holds the low byte (loaded via `LDZ`). This is exactly RET/JP behavior.

Let me map NEXT to this. NEXT reads cell at IP(=DE) low then high, advances IP+2, jumps to cell. I'll model it like `LD dd,(nn)` combined with the `RET`-style jump, but with the source address coming from DE and auto-incrementing.

Let me confirm details of the `aDE` and `aZI` address generation and `Inc_WZ` and how IP (DE) gets advanced. Let me re-read lines 515-523 and the IncDec for DE.

The cleanest approach: use a 4-cycle (M-cycle) instruction:
- **MCycle 1 (M1)**: opcode fetch of ED, then NEXT opcode fetch (handled by prefix mechanism — actually ED is M1, NEXT is also part of... let me verify the prefix timing).

Let me reconsider. ED-prefixed instructions: the ED is fetched in one M1, then the actual opcode in the next M1 (MCycle 1 of the ED-set decode). So in the ED decode, MCycle "001" is the fetch of the NEXT opcode itself. Real memory operations start at MCycle 2.

Let me verify by looking at `LD dd,(nn)` (ED 4B): it uses MCycle 2,3 for fetching nn, 4,5 for reading. Confirmed at lines 1533-1563.

For NEXT, there's no immediate operand; the address is DE. So:
- MCycle 1: opcode fetch (NEXT)
- MCycle 2: set address = DE, read low byte → TmpAddr low (LDZ), inc DE
- MCycle 3: set address = DE, read high byte → DI_Reg (LDW-style / Jump), inc DE
- MCycle 3 end: Jump → PC = DI_Reg & TmpAddr

Let me verify that `LDZ` reads into TmpAddr(7:0) at TState=3 (line 604), and `Jump` uses `DI_Reg` (the high byte just read) at T_Res. And DE increment via `IncDec_16`.

Let me check the increment encoding once more: `IncDec_16` = "0001" means inc DE (bit3=0 → inc, bits1:0=01 → DE). And the RET pattern increments SP with "0111". For DE inc, I'd use "0001".

Let me verify how `LD A,(DE)` sets address and whether I can combine reading + incrementing DE in same cycle. Looking at LDI (lines 441-451): it does Read_To_Acc and IncDec_16 in MCycle 2 together. Good — read and increment can co-occur.

Now I have enough to write the plan. Let me verify the opcode choice — I'll pick **ED 27** (`0x27`, binary `00100111`), which is currently in the big NOP/undocumented list (line 1489 includes `00100111`). Let me confirm.

**Tool: read**

**Input:**
```json
{
  "filePath": "/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd",
  "offset": 1484,
  "limit": 30
}
```

**Output:**
```
<path>/home/louie/RomWBW_MultiComp_MiSTer/Components/Z80/T80_MCode.vhd</path>
<type>file</type>
<content>
1484: 			case IRB is
1485: 			when "00000000"|"00000001"|"00000010"|"00000011"|"00000100"|"00000101"|"00000110"|"00000111"
1486: 				|"00001000"|"00001001"|"00001010"|"00001011"|"00001100"|"00001101"|"00001110"|"00001111"
1487: 				|"00010000"|"00010001"|"00010010"|"00010011"|"00010100"|"00010101"|"00010110"|"00010111"
1488: 				|"00011000"|"00011001"|"00011010"|"00011011"|"00011100"|"00011101"|"00011110"|"00011111"
1489: 				|"00100000"|"00100001"|"00100010"|"00100011"|"00100100"|"00100101"|"00100110"|"00100111"
1490: 				|"00101000"|"00101001"|"00101010"|"00101011"|"00101100"|"00101101"|"00101110"|"00101111"
1491: 				|"00110000"|"00110001"|"00110010"|"00110011"|"00110100"|"00110101"|"00110110"|"00110111"
1492: 				|"00111000"|"00111001"|"00111010"|"00111011"|"00111100"|"00111101"|"00111110"|"00111111"
1493: 
1494: 
1495: 				|"10000000"|"10000001"|"10000010"|"10000011"|"10000100"|"10000101"|"10000110"|"10000111"
1496: 				|"10001000"|"10001001"|"10001010"|"10001011"|"10001100"|"10001101"|"10001110"|"10001111"
1497: 				|"10010000"|"10010001"|"10010010"|"10010011"|"10010100"|"10010101"|"10010110"|"10010111"
1498: 				|"10011000"|"10011001"|"10011010"|"10011011"|"10011100"|"10011101"|"10011110"|"10011111"
1499: 				|                                            "10100100"|"10100101"|"10100110"|"10100111"
1500: 				|                                            "10101100"|"10101101"|"10101110"|"10101111"
1501: 				|                                            "10110100"|"10110101"|"10110110"|"10110111"
1502: 				|                                            "10111100"|"10111101"|"10111110"|"10111111"
1503: 				|"11000000"|"11000001"|"11000010"|"11000011"|"11000100"|"11000101"|"11000110"|"11000111"
1504: 				|"11001000"|"11001001"|"11001010"|"11001011"|"11001100"|"11001101"|"11001110"|"11001111"
1505: 				|"11010000"|"11010001"|"11010010"|"11010011"|"11010100"|"11010101"|"11010110"|"11010111"
1506: 				|"11011000"|"11011001"|"11011010"|"11011011"|"11011100"|"11011101"|"11011110"|"11011111"
1507: 				|"11100000"|"11100001"|"11100010"|"11100011"|"11100100"|"11100101"|"11100110"|"11100111"
1508: 				|"11101000"|"11101001"|"11101010"|"11101011"|"11101100"|"11101101"|"11101110"|"11101111"
1509: 				|"11110000"|"11110001"|"11110010"|"11110011"|"11110100"|"11110101"|"11110110"|"11110111"
1510: 				|"11111000"|"11111001"|"11111010"|"11111011"|"11111100"|"11111101"|"11111110"|"11111111" =>
1511: 				null; -- NOP, undocumented
1512: 			when "01111110"|"01111111" =>
1513: 				-- NOP, undocumented

(Showing lines 1484-1513 of 1934. Use offset=1514 to continue.)
</content>
```

---

## Assistant (Plan · Claude Opus 4.8 · 118.8s)

I have everything needed. Now let me present the complete plan.

## Analysis & Plan: Implementing a FORTH `NEXT` Primitive as `ED` instruction

### What `NEXT` does (semantics)

```
ex de,hl / ld e,(hl) / inc hl / ld d,(hl) / inc hl / ex de,hl / jp (hl)
```

Net effect, with **DE = IP** (Interpreter Pointer):
1. Read a 16-bit cell `W` from memory at address `IP` (low byte first).
2. Advance `IP` by 2 (`DE := DE + 2`).
3. Jump (set PC) to `W` — i.e. `PC := mem[IP], mem[IP+1]`.

BC (TOS), HL (W), SP, IX, IY are *not* disturbed by the macro's net result except HL becomes W (which the old code threw away via `jp (hl)`). In direct-threaded FORTH, HL ends up holding `W` and execution continues at `W`. **Important question below about HL.**

### Chosen opcode

`ED 23` → no, `23` is `LD HL,(nn)`-ish... Within the **ED set**, opcode **`0x23`** (`00100011`) is currently decoded as `null` (NOP/undocumented, line 1489). I propose **`ED 23`** is free, but to avoid any ambiguity I'll select **`ED 27`** (`00100111`), also in the NOP list at line 1489. Both are unused; final choice can be confirmed with you.

### How it maps onto the existing datapath

This reuses three existing, proven mechanisms:

- **`LD dd,(nn)`** (ED 4B, lines 1533–1563): the template for *reading two consecutive bytes from memory into a 16-bit destination using `aZI`/`Inc_WZ`*.
- **`RET`** (lines 1155–1170) and the `Jump` logic (T80.vhd lines 463–467): loads `PC := DI_Reg(hi) & TmpAddr(7:0)` at `T_Res` when `Jump='1'`. `TmpAddr(7:0)` is loaded by `LDZ` (low byte), `DI_Reg` is the just-read high byte.
- **`IncDec_16`** with code `"0001"` to auto-increment **DE** during the two read cycles.

`ISet="10"` (ED) forces `XY_State="00"` (T80.vhd lines 439–442), so no IX/IY interference; `aDE`/`aZI` addressing is straightforward.

### Proposed microcode (T80_MCode.vhd, ED-prefix section)

Add a new `when` arm (and remove `00100111` from the NOP list at line 1489):

```vhdl
when "00100111" =>
    -- NEXT (FORTH inner interpreter primitive)
    -- read cell at (DE)=IP into PC, advance DE by 2
    MCycles <= "011";
    case to_integer(unsigned(MCycle)) is
    when 2 =>
        Set_Addr_To <= aDE;     -- address = IP (DE)
        IncDec_16   <= "0001";  -- DE := DE + 1
        LDZ         <= '1';     -- captured low byte -> TmpAddr(7:0) at TState 3
    when 3 =>
        Set_Addr_To <= aDE;     -- address = IP+1 (DE already incremented)
        IncDec_16   <= "0001";  -- DE := DE + 1  (IP now +2)
        Jump        <= '1';     -- PC := DI_Reg(hi) & TmpAddr(lo)
    when others => null;
    end case;
```

### Key correctness points I verified

1. **`LDZ` timing**: latches `DI_Reg → TmpAddr(7:0)` at `TState=3` (T80.vhd line 604). Read in MCycle 2 completes and is available.
2. **`Jump` timing**: at `T_Res` of MCycle 3, `PC := DI_Reg & TmpAddr(7:0)` (lines 463–467). `DI_Reg` is the high byte read in MCycle 3. ✅ matches RET exactly.
3. **DE increment**: `aDE` reads `RegBusC` (lines 515–516). `IncDec_16="0001"` writes back DE+1 (lines 797–804, 822–825). Read + increment co-occur safely (proven by `LDI`).
4. **The address for the second read** must be DE *after* the first increment. The register-file increment writeback completes by the time MCycle 3 sets the address from `RegBusC` — this needs verification in simulation (see open question 2).

### Open questions for you

I recommend resolving these before I implement:

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "HL = W requirement",
      "question": "The original NEXT macro leaves HL holding W (the address jumped to) via the final `ex de,hl`/`jp (hl)`. Many direct-threaded CamelFORTH CODE words (e.g. DOLIST/ENTER, EXECUTE) rely on HL = W after NEXT. Should the new instruction also load HL with the cell value W (PC), not just jump?",
      "options": [
        {
          "label": "Yes, set HL = W too (Recommended)",
          "description": "Faithfully reproduce the macro: PC := W AND HL := W. Safer for CamelFORTH which assumes W in HL. Slightly more microcode."
        },
        {
          "label": "Jump only, leave HL unchanged",
          "description": "Only set PC := W. Smaller/faster, but may break words that read W from HL. Requires auditing CamelFORTH."
        },
        {
          "label": "Let me check CamelFORTH first",
          "description": "Inspect the CamelFORTH source in RomWBW to determine whether HL=W is actually depended upon before deciding."
        }
      ]
    },
    {
      "header": "Verification approach",
      "question": "There are no automated tests. How do you want correctness verified before/after implementing the microcode change?",
      "options": [
        {
          "label": "ModelSim testbench for the opcode (Recommended)",
          "description": "Write a small VHDL testbench exercising ED-NEXT (read cell, DE+2, PC jump, HL) and check cycle-by-cycle."
        },
        {
          "label": "Full Quartus compile only",
          "description": "Just ensure it synthesizes cleanly via quartus_sh; rely on on-hardware FORTH testing."
        },
        {
          "label": "Plan only, I will verify on hardware",
          "description": "Produce the code change; I will assemble CamelFORTH with the new opcode and test on the DE10-Nano."
        }
      ]
    },
    {
      "header": "CamelFORTH side changes",
      "question": "Implementing the instruction is only half the job. Do you also want the plan to cover updating the CamelFORTH assembly (redefining the `next` macro to emit the single ED opcode)?",
      "options": [
        {
          "label": "Yes, include CamelFORTH macro change",
          "description": "Locate the CamelFORTH source in RomWBW and plan the `next` macro redefinition to emit DB 0EDh,xxh."
        },
        {
          "label": "HDL only for now",
          "description": "Only implement and verify the Z80 core instruction; I will update CamelFORTH separately."
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "The original NEXT macro leaves HL holding W (the address jumped to) via the final `ex de,hl`/`jp (hl)`. Many direct-threaded CamelFORTH CODE words (e.g. DOLIST/ENTER, EXECUTE) rely on HL = W after NEXT. Should the new instruction also load HL with the cell value W (PC), not just jump?"="Let me check CamelFORTH first", "There are no automated tests. How do you want correctness verified before/after implementing the microcode change?"="Plan only, I will verify on hardware", "Implementing the instruction is only half the job. Do you also want the plan to cover updating the CamelFORTH assembly (redefining the `next` macro to emit the single ED opcode)?"="HDL only for now". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Opus 4.8 · 4.8s)

You want me to check CamelFORTH first to determine the HL = W requirement. Let me find the CamelFORTH source in RomWBW.

**Tool: bash**

**Input:**
```json
{
  "description": "Find CamelFORTH source files",
  "command": "find . -iname '*camel*' -o -iname '*forth*' 2>/dev/null | grep -vi '\\.git'"
}
```

**Output:**
```
(no output)
```

---

## Assistant (Plan · Claude Opus 4.8 · 2.8s)

**Tool: bash**

**Input:**
```json
{
  "description": "Search for RomWBW directory and forth refs",
  "command": "ls; echo \"---\"; find . -iname '*romwbw*' 2>/dev/null | grep -vi '\\.git' | head"
}
```

**Output:**
```
AGENTS.md
build_id.v
c5_pin_model_dump.txt
clean.bat
Components
CPM-sd-image
db
incremental_db
IOPORTS.md
IOPORTS.md~
jtag.cdf
MicrocomputerZ80Basic.vhd
MicrocomputerZ80CPM.vhd
MultiComp.qpf
MultiComp.qsf
MultiComp.qws
MultiComp.srf
MultiComp.sv
output_files
pll.xml
README.md
REQUIREMENTS.md
ROMS
rtl
session-ses_18a3.md
session-ses_18f1-2.md
session-ses_18f1.md
sys
testing
Z80 CPM and bootloader (basmon)
---

```

---

## Assistant (Plan · Claude Opus 4.8 · 4.8s)

CamelFORTH isn't present in this repo (RomWBW port is "future" per AGENTS.md). Let me check the CP/M image and any disk content that might hold CamelFORTH.

**Tool: bash**

**Input:**
```json
{
  "description": "Search for next macro and camelforth patterns",
  "command": "grep -rliE 'camelforth|ex de,hl|jp \\(hl\\)|DOLIST|ENTER' . --include='*.asm' --include='*.z80' --include='*.s' --include='*.inc' --include='*.azm' --include='*.mac' 2>/dev/null | grep -vi '\\.git' | head; echo \"=== disk images ===\"; ls -la CPM-sd-image/ 2>/dev/null"
}
```

**Output:**
```
./Z80 CPM and bootloader (basmon)/source/intprt.asm
./Z80 CPM and bootloader (basmon)/source/cbios128.asm
./Z80 CPM and bootloader (basmon)/source/cpm22.asm
./Z80 CPM and bootloader (basmon)/source/basMon.asm
./ROMS/Z80/basic.asm
=== disk images ===
total 8001
drwxr-xr-x  3 louie louie       9 May  6 23:23 .
drwxr-xr-x 13 louie louie      36 Jun  7 03:51 ..
-rw-r--r--  1 louie louie    1222 May  6 23:23 clear-drive-B-to-P.py
-rw-r--r--  1 louie louie 6998289 May  6 23:23 cpm-apps.zip
-rw-r--r--  1 louie louie  163382 May  6 23:23 cpm-blank.zip
-rw-r--r--  1 louie louie   23722 May  6 23:23 cpm_file_copier.py
-rw-r--r--  1 louie louie 1355467 May  6 23:23 cpm.zip
-rw-r--r--  1 louie louie    2316 May  6 23:23 README.MD
drwxr-xr-x  3 louie louie       3 May  6 23:23 TO_IMG

```

---

## Assistant (Plan · Claude Opus 4.8 · 32.7s)

CamelFORTH source is not in this repository (those grep hits are BASIC/CP/M, not FORTH). Since RomWBW/CamelFORTH isn't present, I'll base the HL=W determination on the canonical CamelFORTH source (Bradford Rodriguez's `camel80.azm`), which is the standard RomWBW FORTH.

Let me state the conclusion from the well-known CamelFORTH Z80 model rather than guess.

## Finding: HL = W *is* required

CamelFORTH for Z80 (Brad Rodriguez's `camel80`) is **direct-threaded**, and the comment block you quoted (`HL = W working register`) is from exactly that source. In that model:

- `NEXT` ends with `ex de,hl` / `jp (hl)` — so on entry to the next CODE word, **HL = W = the code field address just jumped to**.
- The high-level runtime words **depend on HL holding W**:
  - **`DOLIST`/`ENTER`** (the colon-word runtime) does `push IP; W→IP` — it reads the parameter-field pointer from `W`, which is in **HL**: `inc hl` (skip the call/jp field) then loads IP from HL.
  - **`DOVAR`/`DOCON`/`DODOES`** likewise compute the parameter field address from **W in HL**.

So a jump-only instruction would break `DOLIST`, `DOVAR`, `DOCON`, etc. **The instruction must set `HL := W` in addition to `PC := W`.**

This changes the microcode: I cannot use the `Jump` path alone, because `Jump` only writes `PC`/`A`, not HL. I need to *also* write the read cell into the HL register pair.

### Revised implementation strategy

Read the cell into the **HL register pair** (like `LD HL,(nn)` does: low→L, high→H), **and** drive `PC` to the same value, while incrementing DE twice.

Two viable mechanisms for the PC update:

1. **`JumpXY` path** (cleanest): `JP (HL)` uses `JumpXY <= '1'`, which at `T_Res` sets `PC := RegBusC` and `A := RegBusC` (T80.vhd lines 468–470), where `RegBusC` is selected to HL (lines 733–737). If I first write the cell into HL during the read cycles, then assert `JumpXY` in the final cycle, I get `PC := HL = W` **and** HL already holds W. This exactly mirrors the macro's `ex de,hl / jp (hl)` ending.

2. Jump path + separate HL write (more complex, redundant).

**Approach 1 (`JumpXY`)** is the faithful, minimal match. Proposed microcode for `ED 27`:

```vhdl
when "00100111" =>
    -- NEXT : HL := mem[DE] (cell W), DE := DE+2, PC := W (=HL)
    MCycles <= "011";
    case to_integer(unsigned(MCycle)) is
    when 2 =>
        Set_Addr_To <= aDE;        -- addr = IP
        IncDec_16   <= "0001";     -- DE := DE+1
        Read_To_Reg <= '1';
        Set_BusA_To <= "0101";     -- write to L
    when 3 =>
        Set_Addr_To <= aDE;        -- addr = IP+1
        IncDec_16   <= "0001";     -- DE := DE+2
        Read_To_Reg <= '1';
        Set_BusA_To <= "0100";     -- write to H
        JumpXY      <= '1';        -- PC := RegBusC (HL = W)
    when others => null;
    end case;
```

**Caveat to verify on hardware (timing hazard):** `JumpXY` reads `RegBusC` (HL) combinationally at `T_Res`, but H is being written into the register file on that same clock edge. The newly-read H byte may not yet be visible on `RegBusC` when `JumpXY` latches PC. The robust alternative is the **`Jump` path** (which uses `DI_Reg & TmpAddr`, i.e. the freshly-read bytes directly, not the register file) for the PC, plus explicitly writing HL:

- MCycle 2: `Set_Addr_To<=aDE; IncDec_16<="0001"; LDZ<='1'; Read_To_Reg<='1'; Set_BusA_To<="0101"` (L = low byte, and TmpAddr(7:0) = low byte).
- MCycle 3: `Set_Addr_To<=aDE; IncDec_16<="0001"; Jump<='1'; Read_To_Reg<='1'; Set_BusA_To<="0100"` (H = high byte = DI_Reg; PC := DI_Reg & TmpAddr).

This uses the **same data sources `RET` uses for PC** (no register-file read hazard) while *also* committing the bytes to L and H. This is the safer design and I recommend it.

### Final plan (HDL only, you verify on hardware)

1. **`Components/Z80/T80_MCode.vhd`**
   - Remove `"00100111"` from the ED NOP/undocumented list at line 1489.
   - Add the new `when "00100111" =>` arm (the `Jump`-path version above: 3 M-cycles; reads cell at DE into HL, increments DE twice, sets PC := cell via `Jump`).
2. **No changes needed** to `T80.vhd`, `T80_Reg.vhd`, `T80_Pack.vhd`, `T80_ALU.vhd`, or `T80s.vhd` — the new instruction is composed entirely from existing control signals (`Set_Addr_To=aDE`, `IncDec_16`, `Read_To_Reg`, `Set_BusA_To`, `LDZ`, `Jump`). No port/interface changes, so the package and wrappers are untouched.
3. **`MultiComp.qsf`**: no change — `T80_MCode.vhd` is already in the build.

**Cost/benefit:** Replaces the 7-byte inline macro at the end of every CODE word with a 2-byte `ED 27`, saving 5 bytes per primitive (CamelFORTH has ~150+ CODE words → ~750+ bytes saved) and collapsing 7 instructions (~30+ T-states) into one ~12 T-state instruction.

**Open item before coding:** confirm the opcode. I propose **`ED 27`** (`00100111`). If you'd prefer a different free ED slot (e.g. `ED 23`), tell me; otherwise I'll proceed with `ED 27` when you switch me out of plan mode.

Would you like me to proceed with the `Jump`-path implementation using `ED 27` once you approve?

---

