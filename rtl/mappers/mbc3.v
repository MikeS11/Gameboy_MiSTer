module mbc3 (
	input             enable,
	input             reset,

	input             clk_sys,
	input             ce_cpu,

	input             savestate_load,
	input      [15:0] savestate_data,
	inout      [15:0] savestate_back_b,

	input      [32:0] RTC_time,
	output reg [31:0] RTC_timestampOut,
	output reg [31:0] RTC_savedtimeOut,
	output reg        RTC_inuse,

	input             bk_wr,
	input             bk_rtc_wr,
	input      [16:0] bk_addr,
	input      [15:0] bk_data,
	input      [63:0] img_size,

	input             has_ram,
	input       [1:0] ram_mask,
	input       [6:0] rom_mask,

	input      [15:0] cart_addr,
	input       [7:0] cart_mbc_type,

	input             cart_wr,
	input       [7:0] cart_di,

	input       [7:0] cram_di,
	inout       [7:0] cram_do_b,
	inout      [16:0] cram_addr_b,

	inout       [9:0] mbc_bank_b,
	inout             ram_enabled_b,
	inout             has_battery_b
);

wire [9:0] mbc_bank;
wire [7:0] cram_do;
wire [16:0] cram_addr;
wire ram_enabled;
wire has_battery;
wire [15:0] savestate_back;

assign mbc_bank_b       = enable ? mbc_bank       : 10'hZ;
assign cram_do_b        = enable ? cram_do        :  8'hZ;
assign cram_addr_b      = enable ? cram_addr      : 17'hZ;
assign ram_enabled_b    = enable ? ram_enabled    :  1'hZ;
assign has_battery_b    = enable ? has_battery    :  1'hZ;
assign savestate_back_b = enable ? savestate_back : 16'hZ;

wire [1:0] mbc3_ram_bank = mbc_ram_bank_reg[1:0] & ram_mask[1:0];

// 0x0000-0x3FFF = Bank 0
wire [6:0] mbc_rom_bank = (cart_addr[15:14] == 2'b00) ? 7'd0 : mbc_rom_bank_reg;

// mask address lines to enable proper mirroring
wire [6:0] mbc3_rom_bank = mbc_rom_bank[6:0] & rom_mask[6:0];  //128


// --------------------- CPU register interface ------------------

reg [6:0] mbc_rom_bank_reg;
reg [1:0] mbc_ram_bank_reg;
reg mbc_ram_enable;
reg mbc3_mode;

assign savestate_back[ 6: 0] = mbc_rom_bank_reg;
assign savestate_back[ 8: 7] = 0;
assign savestate_back[10: 9] = mbc_ram_bank_reg;
assign savestate_back[13:11] = 0;
assign savestate_back[   14] = mbc3_mode;
assign savestate_back[   15] = mbc_ram_enable;

always @(posedge clk_sys) begin
	if(savestate_load & enable) begin
		mbc_rom_bank_reg <= savestate_data[ 6: 0]; //7'd1;
		mbc_ram_bank_reg <= savestate_data[10: 9]; //2'd0;
		mbc3_mode        <= savestate_data[   14]; //1'b0;
		mbc_ram_enable   <= savestate_data[   15]; //1'b0;
	end else if(~enable) begin
		mbc_rom_bank_reg <= 7'd1;
		mbc_ram_bank_reg <= 2'd0;
		mbc3_mode        <= 1'b0;
		mbc_ram_enable   <= 1'b0;
	end else if(ce_cpu) begin
		if (cart_wr & ~cart_addr[15]) begin
			case(cart_addr[14:13])
				2'b00: mbc_ram_enable <= (cart_di[3:0] == 4'ha); //RAM enable/disable
				2'b01: mbc_rom_bank_reg <= (cart_di[6:0] == 7'd0) ? 7'd1 : cart_di[6:0]; //write to ROM bank register
				2'b10: begin
					if (cart_di[3]) begin
						mbc3_mode <= 1'b1; //enable RTC
						rtc_index <= cart_di[2:0];
					end else begin
						mbc3_mode <= 1'b0; //enable RAM
						mbc_ram_bank_reg <= cart_di[1:0]; //write to RAM bank register
					end
				end
				2'b11: ; // TODO: Latch RTC data
			endcase
		end
	end
end

assign mbc_bank = { 2'b00, mbc3_rom_bank, cart_addr[13] };	// 16k ROM Bank 0-127

reg [7:0] cram_do_r;
always @* begin
	cram_do_r = 8'hFF; // Ram not enabled
	if (mbc_ram_enable) begin
		if (mbc3_mode)
			cram_do_r = rtc_return; // RTC mode
		else if (has_ram)
			cram_do_r = cram_di;
	end
end

assign cram_do = cram_do_r;
assign cram_addr = { 2'b00, mbc3_ram_bank, cart_addr[12:0] };

assign has_battery = (cart_mbc_type == 8'h0F || cart_mbc_type == 8'h10 || cart_mbc_type == 8'h13);
assign ram_enabled = mbc_ram_enable & has_ram;

/////////////////////////////  RTC  ///////////////////////////////
reg [2:0]  rtc_index;

reg [25:0] rtc_subseconds;
reg [5:0]  rtc_seconds;
reg [5:0]  rtc_minutes;
reg [4:0]  rtc_hours;
reg [9:0]  rtc_days;
reg        rtc_overflow;
reg        rtc_halt;

wire [7:0] rtc_return;

wire        RTC_timestampNew = RTC_time[32];
wire [31:0] RTC_timestampIn  = RTC_time[31:0];	

reg [31:0] RTC_timestampSaved = 0;
reg [31:0] RTC_savedtimeIn = 0;	
reg        RTC_saveLoaded = 0;

reg rtc_change;
reg RTC_saveLoaded_1;
reg RTC_timestampNew_1; 
reg [31:0] diffSeconds;

reg reset_1;

always @(posedge clk_sys) begin

	reset_1 <= reset;

	if(!reset_1 && reset) begin
		rtc_halt  <= 1'b0;
		RTC_inuse <= 1'b0;
	end else begin

		if (rtc_change == 1'b0) begin // when RTC hasn't changed recently, update the register which will be written after savegame
			RTC_savedtimeOut <= {3'd0, rtc_halt, rtc_overflow, rtc_days, rtc_hours, rtc_minutes, rtc_seconds};
		end

		rtc_change	  <= 1'b0;
		rtc_subseconds <= rtc_subseconds + 1'd1;

		if (mbc3_mode || (bk_wr && enable && img_size[9])) begin  // RTC is either used by game or already used in savegame
			RTC_inuse <= 1'b1;
		end

		RTC_saveLoaded <= 1'b0;
		if (bk_rtc_wr) begin // load data from savefile to intermediate register
			case (bk_addr[7:0])
				0: RTC_timestampSaved[15:0]  <= bk_data;
				1: RTC_timestampSaved[31:16] <= bk_data;
				2: RTC_savedtimeIn[15:0]     <= bk_data;
				3: RTC_savedtimeIn[31:16]    <= bk_data;
				4: RTC_saveLoaded            <= 1'b1;
			endcase
		end

		if (RTC_saveLoaded == 1'b1) begin  // load data from intermediate register to RTC registers

			if (RTC_timestampOut > RTC_timestampSaved) begin
				diffSeconds <= RTC_timestampOut - RTC_timestampSaved;
			end

			rtc_seconds	 <= RTC_savedtimeIn[5:0];
			rtc_minutes	 <= RTC_savedtimeIn[11:6];
			rtc_hours	 <= RTC_savedtimeIn[16:12];
			rtc_days		 <= RTC_savedtimeIn[26:17];
			rtc_overflow <= RTC_savedtimeIn[27];
			rtc_halt		 <= RTC_savedtimeIn[28];

			RTC_inuse    <= 1'b1;

		end else if(cart_wr && (cart_addr[15:13] == 3'b101) && mbc3_mode == 1'b1) begin // setting RTC registers from game

			case (rtc_index)
				0: rtc_seconds	  <= cart_di[5:0]; 
				1: rtc_minutes	  <= cart_di[5:0]; 
				2: rtc_hours	  <= cart_di[4:0]; 
				3: rtc_days[7:0] <= cart_di; 
				4: begin
					rtc_days[8]   <= cart_di[0]; 
					rtc_halt      <= cart_di[6]; 
					rtc_overflow  <= cart_di[7];
				end
			endcase

		end else begin  // normal counting

			if (rtc_halt == 1'b0) begin
				if (rtc_seconds >= 60)	 begin rtc_seconds <= 6'd0;  rtc_minutes  <= rtc_minutes + 1'd1; rtc_change <= 1'b1; end
				if (rtc_minutes >= 60)	 begin rtc_minutes <= 6'd0;  rtc_hours    <= rtc_hours + 1'd1;	  rtc_change <= 1'b1; end
				if (rtc_hours   >= 24)	 begin rtc_hours   <= 5'd0;  rtc_days     <= rtc_days + 1'd1;    rtc_change <= 1'b1; end
				if (rtc_days    >= 512)	 begin rtc_days    <= 10'd0; rtc_overflow <= 1'b1;               rtc_change <= 1'b1; end
			end

			if (rtc_subseconds >= 33554432) begin 
				rtc_subseconds	  <= 26'd0; 
				RTC_timestampOut	<= RTC_timestampOut + 1'd1;
				if (rtc_halt == 1'b0) begin
					rtc_seconds	  <= rtc_seconds + 1'd1;
					rtc_change	<= 1'b1; 
				end
			end else if (diffSeconds > 0 && rtc_change == 1'b0) begin // fast counting loaded seconds
				diffSeconds		  <= diffSeconds - 1'd1; 
				if (rtc_halt == 1'b0) begin
					rtc_seconds	  <= rtc_seconds + 1'd1;
					rtc_change		<= 1'b1; 
				end
			end

		end

		RTC_timestampNew_1 <= RTC_timestampNew;  // saving timestamp from HPS
		if (RTC_timestampNew != RTC_timestampNew_1) begin
			RTC_timestampOut <= RTC_timestampIn;
		end

	end
end

assign rtc_return = 
	(rtc_index == 0) ? rtc_seconds   :
	(rtc_index == 1) ? rtc_minutes   :
	(rtc_index == 2) ? rtc_hours     :
	(rtc_index == 3) ? rtc_days[7:0] :
	(rtc_index == 4) ? {rtc_overflow, rtc_halt, 5'b00000, rtc_days[8]} :
	8'hFF;

endmodule