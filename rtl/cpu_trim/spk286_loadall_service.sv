// SPDX-License-Identifier: MIT
// Stand-in for spk286_loadall_service of SPK286 (ref/SPK286/rtl), same ports: the LOADALL instruction
// is not there. An attempt ends in a general protection fault, and the logic that the real
// block needs in the rest of the CPU is removed by synthesis. Build with FULLCPU=1 for the
// real one.
`timescale 1ns/1ps
module spk286_loadall_service (

    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic        current_protected,
    input  logic [1:0]  current_cpl,
    input  logic        memory_done,
    input  logic [15:0] memory_read_data,
    output logic        memory_request,
    output logic        memory_write,
    output logic        memory_byte,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    output logic        busy,
    output logic        complete,
    output logic        fault,
    output logic [7:0]  fault_vector,
    output logic [15:0] fault_error_code,
    output logic        commit_valid,
    output logic [15:0] loaded_msw,
    output logic [15:0] loaded_ip,
    output logic [15:0] loaded_flags,
    output logic [127:0] loaded_gpr,
    output logic [15:0] loaded_gdtr_limit,
    output logic [23:0] loaded_gdtr_base,
    output logic [15:0] loaded_idtr_limit,
    output logic [23:0] loaded_idtr_base,
    output logic [15:0] loaded_ldtr_selector,
    output logic [23:0] loaded_ldtr_base,
    output logic [15:0] loaded_ldtr_limit,
    output logic [7:0]  loaded_ldtr_access,
    output logic [3:0]  loaded_ldtr_class,
    output logic        loaded_ldtr_valid,
    output logic        loaded_ldtr_present,
    output logic [15:0] loaded_tr_selector,
    output logic [23:0] loaded_tr_base,
    output logic [15:0] loaded_tr_limit,
    output logic [7:0]  loaded_tr_access,
    output logic [3:0]  loaded_tr_class,
    output logic        loaded_tr_valid,
    output logic        loaded_tr_present,
    output logic [63:0] cache_selectors,
    output logic [95:0] cache_bases,
    output logic [63:0] cache_limits,
    output logic [31:0] cache_access,
    output logic [15:0] cache_classes,
    output logic [3:0]  cache_valid,
    output logic [3:0]  cache_present,
    output logic [3:0]  cache_protected,
    output logic [7:0]  cache_dpl,
    output logic [3:0]  cache_tables,
    output logic [7:0]  cache_rpl
);
    logic busy_q, fault_q;
    always_ff @(posedge clk) begin
        busy_q  <= start && !reset && !cancel;
        fault_q <= busy_q && !reset && !cancel;
    end
    assign busy  = busy_q;
    assign fault = fault_q;
    assign fault_vector = 8'd13;
    assign fault_error_code = 16'h0000;
    assign memory_request = '0;
    assign memory_write = '0;
    assign memory_byte = '0;
    assign memory_address = '0;
    assign memory_write_data = '0;
    assign complete = '0;
    assign commit_valid = '0;
    assign loaded_msw = '0;
    assign loaded_ip = '0;
    assign loaded_flags = '0;
    assign loaded_gpr = '0;
    assign loaded_gdtr_limit = '0;
    assign loaded_gdtr_base = '0;
    assign loaded_idtr_limit = '0;
    assign loaded_idtr_base = '0;
    assign loaded_ldtr_selector = '0;
    assign loaded_ldtr_base = '0;
    assign loaded_ldtr_limit = '0;
    assign loaded_ldtr_access = '0;
    assign loaded_ldtr_class = '0;
    assign loaded_ldtr_valid = '0;
    assign loaded_ldtr_present = '0;
    assign loaded_tr_selector = '0;
    assign loaded_tr_base = '0;
    assign loaded_tr_limit = '0;
    assign loaded_tr_access = '0;
    assign loaded_tr_class = '0;
    assign loaded_tr_valid = '0;
    assign loaded_tr_present = '0;
    assign cache_selectors = '0;
    assign cache_bases = '0;
    assign cache_limits = '0;
    assign cache_access = '0;
    assign cache_classes = '0;
    assign cache_valid = '0;
    assign cache_present = '0;
    assign cache_protected = '0;
    assign cache_dpl = '0;
    assign cache_tables = '0;
    assign cache_rpl = '0;
endmodule
