// mlc_binds.sv - attach the checkers in mlc_checkers.sv to the RTL. Signal names in the RTL are a contract with the checkers.
bind l1_cache_ctrl     mlc_l1_chk    u_chk (.*, .state(state), .is_hit(is_hit), .wr_fwd_pending(wr_fwd_pending), .miss_is_write(miss_is_write),
                                             .conflict(valid_array[req_index]));
bind l2_cache_ctrl     mlc_l2_chk    #(.LINE_B(LINE_B), .WAYS(WAYS), .OFFSET_W(OFFSET_W), .INDEX_W(INDEX_W), .TAG_W(TAG_W)) u_chk (.*,
                                             .state(state), .is_hit(is_hit), .miss_is_write(miss_is_write), .way_hit(way_hit),
                                             .victim_valid(valid_array[miss_index][victim_way_latched]), .victim_dirty(dirty_array[miss_index][victim_way_latched]),
                                             .victim_valid_now(valid_array[miss_index][victim_way]), .victim_dirty_now(dirty_array[miss_index][victim_way]),
                                             .set_full(&set_valid), .plru_access_valid(plru_access_valid), .miss_index(miss_index), .miss_tag(miss_tag),
                                             .victim_tag_latched(victim_tag_latched));
bind l1_l2_arbiter     mlc_arb_chk   u_chk (.*, .busy(busy), .owner(owner), .last(last), .sel(sel));
bind plru_tree         mlc_plru_chk  #(.WAYS(WAYS), .SETS(SETS)) u_chk (.*);
bind axi4_fill_engine  mlc_axi_chk   #(.LINE_B(LINE_B), .AXI_DATA_W(AXI_DATA_W)) u_chk (.*, .state(state), .beat_q(32'(beat_q)));
bind l2_l3_width_adapter mlc_adapter_chk #(.L2_LINE_B(L2_LINE_B), .L3_LINE_B(L3_LINE_B)) u_chk (.*);
