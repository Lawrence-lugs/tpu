
// Feature map dimension ordering in memory
// Channels, Xpos, Ypos
// Fastest-changing index is channel

module buffer_router
#(
    parameter dataSize = 8,
    parameter numRegister = 256,
    parameter nElementsOut = 9, // == nPEy of systolic array

    // Configurable with proper orchestration
    // Param for now
    localparam kernelWidth = $sqrt(nElementsOut), 
    localparam nAddress = $clog2(numRegister),

    // Configurable with proper orchestration
    // Param for now
    parameter nOfmapElements = 3, // == nPEx of systolic array, for now
    parameter outputSize = 24
) ( 
    input clk,
    input nrst,

    // I/O
    input [dataSize-1:0] wr_data,
    input [nAddress-1:0] wr_addr,
    input wr_en,
    output reg [dataSize-1:0] rd_data [nElementsOut],

    // OFMAP writeback
    input [outputSize-1:0] wr_data_ofmap [nOfmapElements],
    input ofmap_valid_i,

    // Configuration
    input [15:0] cfg_ifmap_width,

    // Control
    input ctrl_start,
    output reg flag_done
);

// DERIVED CONFIG
wire [15:0] cfg_ofmap_width;
assign cfg_ofmap_width = cfg_ifmap_width - 3 + 1; // Assuming valid convolutions

// OFMAP WRITEBACK
// not scalable to pingpong, need to track ifmap_start_pointer for that.
logic [nAddress-1:0] ofmap_start_addr;
logic [nAddress-1:0] wr_ptr_ofmap;
always_comb begin : OfmapAddr
    ofmap_start_addr = (cfg_ifmap_width**2); // add ifmap channels someday
end

// REGISTER FILE AND WRITING
logic [numRegister-1:0][dataSize-1:0] registers;
always @( posedge clk or negedge nrst ) begin : RegFile
    if (!nrst) begin
        for (int i = 0; i < numRegister; i = i + 1) begin
            registers[i] <= 0;
        end
        wr_ptr_ofmap <= 0;
    end else begin
        if (wr_en) begin
            registers[wr_addr] <= wr_data;
        end
        if (ofmap_valid_i) begin
            for (int i = 0; i < nOfmapElements; i = i + 1) begin
                registers[ofmap_start_addr + wr_ptr_ofmap + i] <= wr_data_ofmap[i];
            end
            wr_ptr_ofmap <= wr_ptr_ofmap + nOfmapElements;
        end
    end
end

// READING LOGIC AND FSM
reg [nAddress-1:0] out_pixel_loc_x;
reg [nAddress-1:0] out_pixel_loc_y;

typedef enum logic [3:0] { 
    S_IDLE,
    S_COMPUTE
} router_state_t;
router_state_t state_q;
router_state_t state_d;

always_comb begin : stateD
    flag_done = 0;
    state_d = S_IDLE;
    case (state_q)
        S_IDLE    : begin
            if (ctrl_start) begin
                state_d = S_COMPUTE; 
            end
        end 
        S_COMPUTE : begin
            if (out_pixel_loc_x == cfg_ofmap_width-1 && out_pixel_loc_y == cfg_ofmap_width-1) begin
                state_d = S_IDLE;
                flag_done = 1;
            end else begin
                state_d = S_COMPUTE;
                flag_done = 0;
            end
        end 
        default : begin
            state_d = S_IDLE;
        end
    endcase
end

always_ff @ (posedge clk or negedge nrst) begin
    if(!nrst) begin
        state_q <= S_IDLE;
    end else begin
        state_q <= state_d;
    end
end

// TOEPLITZ READ DATA LOGIC

always @ (posedge clk or negedge nrst) begin : OfmapPos
    if(!nrst) begin
        out_pixel_loc_x <= 0;
        out_pixel_loc_y <= 0;
    end else begin
        case (state_q)
            S_COMPUTE: begin
                // Traversing row-major over ofmap
                if (out_pixel_loc_x == cfg_ofmap_width-1) begin
                    out_pixel_loc_x <= 0;
                    out_pixel_loc_y <= out_pixel_loc_y + 1;
                end else begin
                    out_pixel_loc_x <= out_pixel_loc_x + 1;
                    out_pixel_loc_y <= out_pixel_loc_y;
                end
            end 
            default: begin
                out_pixel_loc_x <= 0;
                out_pixel_loc_y <= 0;
            end
        endcase
    end
end


reg [dataSize-1:0] rd_data_flat [nElementsOut];

always@(*) begin : ReadDataFromOfmapPos
    case (state_q)
        S_COMPUTE : begin
            for (int i = 0; i < kernelWidth; i++ ) begin
                for (int j = 0; j < kernelWidth; j++ ) begin
                    automatic int addr = j*kernelWidth + i;
                    automatic int regAddr = (out_pixel_loc_x + i) + (out_pixel_loc_y + j) * cfg_ifmap_width;
                    rd_data[addr] = registers[regAddr];
                end
            end
        end 
        default : begin
            for (int i = 0; i < nElementsOut; i = i + 1) begin
                rd_data[i] = 0;
            end
        end 
    endcase
end

endmodule