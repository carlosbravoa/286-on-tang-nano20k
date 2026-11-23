`timescale 1ns/1ps
module speed_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles=0, retires=0, waits=0;
    spk286 dut (.*);
    initial begin
        if(!$value$plusargs("waits=%d",waits)) waits=0;
        $readmemh("loop.hex",memory);
        timing_policy_request=2'd2; execute_enable=1; reset=1; ready=1;
        repeat(4) begin #5 clk=1; #5 clk=0; end
        reset=0;
        while(!halted && cycles<2000000) begin
            #1; data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
            ready = (waits==0) || (cycles%(waits+1)==0);
            if(bus_valid && ready && bus_write) begin
                if(!address[0]) memory[address[15:0]]=data_out[7:0];
                if(!bus_bhe_n) memory[{address[15:1],1'b1}]=data_out[15:8];
            end
            #4 clk=1; #5 clk=0; cycles=cycles+1;
            if(instruction_retired) retires=retires+1;
        end
        $display("waits=%0d halted=%b cycles=%0d retired=%0d clk/instr=%.2f cycles/iteration=%.1f (real 286: 65 clocks/iteration)",
                 waits,halted,cycles,retires,1.0*cycles/retires,cycles/1000.0);
        $finish;
    end
endmodule
