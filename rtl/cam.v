module cam_d8_w104 (
    search_key,
    wr_key,
    wr_idx,
    wr_en,
    clear,
    clock,
    wr_valid,
    match_found,
    match_idx,
    free_idx,
    full
);

    input [103:0] search_key;
    input [103:0] wr_key;
    input [2:0] wr_idx;
    input wr_en;
    input clear;
    input clock;
    input wr_valid;
    output match_found;
    output [2:0] match_idx;
    output [2:0] free_idx;
    output full;

    /* signal declarations */
    wire _77 = 1'b0;
    wire _76 = 1'b0;
    wire _26;
    wire _34;
    wire _42;
    wire _50;
    wire _58;
    wire _66;
    wire _74;
    wire _75;
    reg _79;
    wire [2:0] _98 = 3'b000;
    wire [2:0] _97 = 3'b000;
    wire [2:0] _95 = 3'b000;
    wire [2:0] _93 = 3'b001;
    wire [2:0] _91 = 3'b010;
    wire [2:0] _89 = 3'b011;
    wire [2:0] _87 = 3'b100;
    wire [2:0] _85 = 3'b101;
    wire [2:0] _83 = 3'b110;
    wire [2:0] _81 = 3'b111;
    wire [2:0] _80 = 3'b000;
    wire _73;
    wire [2:0] _82;
    wire _65;
    wire [2:0] _84;
    wire _57;
    wire [2:0] _86;
    wire _49;
    wire [2:0] _88;
    wire _41;
    wire [2:0] _90;
    wire _33;
    wire [2:0] _92;
    wire _25;
    wire [2:0] _94;
    wire _18;
    wire [2:0] _96;
    reg [2:0] _99;
    wire [2:0] _158 = 3'b000;
    wire [2:0] _157 = 3'b000;
    wire [2:0] _155 = 3'b000;
    wire [2:0] _153 = 3'b001;
    wire [2:0] _151 = 3'b010;
    wire [2:0] _149 = 3'b011;
    wire [2:0] _147 = 3'b100;
    wire [2:0] _145 = 3'b101;
    wire [2:0] _143 = 3'b110;
    wire [2:0] _141 = 3'b111;
    wire [2:0] _140 = 3'b000;
    wire [2:0] _142;
    wire [2:0] _144;
    wire [2:0] _146;
    wire [2:0] _148;
    wire [2:0] _150;
    wire [2:0] _152;
    wire [2:0] _154;
    wire [2:0] _156;
    reg [2:0] _159;
    wire vdd = 1'b1;
    wire _168 = 1'b0;
    wire _167 = 1'b0;
    wire [103:0] _136 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _135 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _137;
    wire _138;
    wire [2:0] _69 = 3'b111;
    wire _70;
    wire _71;
    wire _68 = 1'b0;
    wire _67 = 1'b0;
    reg _72;
    wire _139;
    wire [103:0] _131 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _130 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _132;
    wire _133;
    wire [2:0] _61 = 3'b110;
    wire _62;
    wire _63;
    wire _60 = 1'b0;
    wire _59 = 1'b0;
    reg _64;
    wire _134;
    wire [103:0] _126 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _125 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _127;
    wire _128;
    wire [2:0] _53 = 3'b101;
    wire _54;
    wire _55;
    wire _52 = 1'b0;
    wire _51 = 1'b0;
    reg _56;
    wire _129;
    wire [103:0] _121 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _120 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _122;
    wire _123;
    wire [2:0] _45 = 3'b100;
    wire _46;
    wire _47;
    wire _44 = 1'b0;
    wire _43 = 1'b0;
    reg _48;
    wire _124;
    wire [103:0] _116 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _115 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _117;
    wire _118;
    wire [2:0] _37 = 3'b011;
    wire _38;
    wire _39;
    wire _36 = 1'b0;
    wire _35 = 1'b0;
    reg _40;
    wire _119;
    wire [103:0] _111 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _110 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _112;
    wire _113;
    wire [2:0] _29 = 3'b010;
    wire _30;
    wire _31;
    wire _28 = 1'b0;
    wire _27 = 1'b0;
    reg _32;
    wire _114;
    wire [103:0] _106 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _105 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _107;
    wire _108;
    wire [2:0] _21 = 3'b001;
    wire _22;
    wire _23;
    wire _20 = 1'b0;
    wire _19 = 1'b0;
    reg _24;
    wire _109;
    wire [103:0] _101 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    wire [103:0] _100 = 104'b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    reg [103:0] _102;
    wire _103;
    wire [2:0] _14 = 3'b000;
    wire _15;
    wire _16;
    wire _13 = 1'b0;
    wire _12 = 1'b0;
    reg _17;
    wire _104;
    wire _160;
    wire _161;
    wire _162;
    wire _163;
    wire _164;
    wire _165;
    wire _166;
    reg _169;

    /* logic */
    assign _26 = _18 | _25;
    assign _34 = _26 | _33;
    assign _42 = _34 | _41;
    assign _50 = _42 | _49;
    assign _58 = _50 | _57;
    assign _66 = _58 | _65;
    assign _74 = _66 | _73;
    assign _75 = ~ _74;
    always @(posedge clock) begin
        if (clear)
            _79 <= _77;
        else
            _79 <= _75;
    end
    assign _73 = ~ _72;
    assign _82 = _73 ? _81 : _80;
    assign _65 = ~ _64;
    assign _84 = _65 ? _83 : _82;
    assign _57 = ~ _56;
    assign _86 = _57 ? _85 : _84;
    assign _49 = ~ _48;
    assign _88 = _49 ? _87 : _86;
    assign _41 = ~ _40;
    assign _90 = _41 ? _89 : _88;
    assign _33 = ~ _32;
    assign _92 = _33 ? _91 : _90;
    assign _25 = ~ _24;
    assign _94 = _25 ? _93 : _92;
    assign _18 = ~ _17;
    assign _96 = _18 ? _95 : _94;
    always @(posedge clock) begin
        if (clear)
            _99 <= _98;
        else
            _99 <= _96;
    end
    assign _142 = _139 ? _141 : _140;
    assign _144 = _134 ? _143 : _142;
    assign _146 = _129 ? _145 : _144;
    assign _148 = _124 ? _147 : _146;
    assign _150 = _119 ? _149 : _148;
    assign _152 = _114 ? _151 : _150;
    assign _154 = _109 ? _153 : _152;
    assign _156 = _104 ? _155 : _154;
    always @(posedge clock) begin
        if (clear)
            _159 <= _158;
        else
            _159 <= _156;
    end
    always @(posedge clock) begin
        if (clear)
            _137 <= _136;
        else
            if (_71)
                _137 <= wr_key;
    end
    assign _138 = _137 == search_key;
    assign _70 = wr_idx == _69;
    assign _71 = wr_en & _70;
    always @(posedge clock) begin
        if (clear)
            _72 <= _68;
        else
            if (_71)
                _72 <= wr_valid;
    end
    assign _139 = _72 & _138;
    always @(posedge clock) begin
        if (clear)
            _132 <= _131;
        else
            if (_63)
                _132 <= wr_key;
    end
    assign _133 = _132 == search_key;
    assign _62 = wr_idx == _61;
    assign _63 = wr_en & _62;
    always @(posedge clock) begin
        if (clear)
            _64 <= _60;
        else
            if (_63)
                _64 <= wr_valid;
    end
    assign _134 = _64 & _133;
    always @(posedge clock) begin
        if (clear)
            _127 <= _126;
        else
            if (_55)
                _127 <= wr_key;
    end
    assign _128 = _127 == search_key;
    assign _54 = wr_idx == _53;
    assign _55 = wr_en & _54;
    always @(posedge clock) begin
        if (clear)
            _56 <= _52;
        else
            if (_55)
                _56 <= wr_valid;
    end
    assign _129 = _56 & _128;
    always @(posedge clock) begin
        if (clear)
            _122 <= _121;
        else
            if (_47)
                _122 <= wr_key;
    end
    assign _123 = _122 == search_key;
    assign _46 = wr_idx == _45;
    assign _47 = wr_en & _46;
    always @(posedge clock) begin
        if (clear)
            _48 <= _44;
        else
            if (_47)
                _48 <= wr_valid;
    end
    assign _124 = _48 & _123;
    always @(posedge clock) begin
        if (clear)
            _117 <= _116;
        else
            if (_39)
                _117 <= wr_key;
    end
    assign _118 = _117 == search_key;
    assign _38 = wr_idx == _37;
    assign _39 = wr_en & _38;
    always @(posedge clock) begin
        if (clear)
            _40 <= _36;
        else
            if (_39)
                _40 <= wr_valid;
    end
    assign _119 = _40 & _118;
    always @(posedge clock) begin
        if (clear)
            _112 <= _111;
        else
            if (_31)
                _112 <= wr_key;
    end
    assign _113 = _112 == search_key;
    assign _30 = wr_idx == _29;
    assign _31 = wr_en & _30;
    always @(posedge clock) begin
        if (clear)
            _32 <= _28;
        else
            if (_31)
                _32 <= wr_valid;
    end
    assign _114 = _32 & _113;
    always @(posedge clock) begin
        if (clear)
            _107 <= _106;
        else
            if (_23)
                _107 <= wr_key;
    end
    assign _108 = _107 == search_key;
    assign _22 = wr_idx == _21;
    assign _23 = wr_en & _22;
    always @(posedge clock) begin
        if (clear)
            _24 <= _20;
        else
            if (_23)
                _24 <= wr_valid;
    end
    assign _109 = _24 & _108;
    always @(posedge clock) begin
        if (clear)
            _102 <= _101;
        else
            if (_16)
                _102 <= wr_key;
    end
    assign _103 = _102 == search_key;
    assign _15 = wr_idx == _14;
    assign _16 = wr_en & _15;
    always @(posedge clock) begin
        if (clear)
            _17 <= _13;
        else
            if (_16)
                _17 <= wr_valid;
    end
    assign _104 = _17 & _103;
    assign _160 = _104 | _109;
    assign _161 = _160 | _114;
    assign _162 = _161 | _119;
    assign _163 = _162 | _124;
    assign _164 = _163 | _129;
    assign _165 = _164 | _134;
    assign _166 = _165 | _139;
    always @(posedge clock) begin
        if (clear)
            _169 <= _168;
        else
            _169 <= _166;
    end

    /* aliases */

    /* output assignments */
    assign match_found = _169;
    assign match_idx = _159;
    assign free_idx = _99;
    assign full = _79;

endmodule
