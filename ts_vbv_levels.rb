require 'fileutils'
require 'gnuplot'

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream
CLOCKS_PER_SEC = 27000000

@pid_counter = Hash.new(0)
@total_packet_count = 0
@selected_pid = 0
@pusi = 0
@mp2_pic_types = {1.to_s=>'I', 2.to_s=>'P',3.to_s=>'B'}
@pcr_pos_per_pid = Hash.new{|hsh,key| hsh[key] = [] }
@dts_pos_per_pid = Hash.new{|hsh,key| hsh[key] = [] }
@plot_vbv_levels = Array.new(0)

def processAdaptationField b, pid, af_control
  
  af_length = (af_control == 0x1) ? -1 : b[4]     #0x1 means payload only. There is no length byte so -1
  
  #Just get PCR from AF 
  if(af_length > 0)
    pcr_flag = (b[5] & 0x10) >> 4
    if(pcr_flag == 0x1)
      pcr_base = (b[6]) << 25 | (b[7] << 17) | (b[8] << 9) | (b[9] << 1) | (b[10] & 80)
      pcr_extension = ((b[10] & 0x1) << 8) | b[11]    
      pcr = pcr_base * 300 + pcr_extension 
      #puts "PCR: #{pcr}" unless pid.to_s(10) != @selected_pid
      value = [pcr, @pid_counter[pid]]
      @pcr_pos_per_pid[pid].push value unless pid.to_s(10) != @selected_pid
    end
  end
  
  #PES parsing
  unless (af_length > 183 || @pusi == 0)
    pes_start_pos = 4 + af_length + 1    
	
    pes_start_code = b[pes_start_pos] << 16 | b[pes_start_pos+1] << 8 | b[pes_start_pos+2] unless (af_length > 180)
    
    if(pes_start_code == 0x1)
      pes_stream_id = b[pes_start_pos + 3] #Ex for video, #Cx for audio  
      pes_length = b[pes_start_pos + 4] << 8 | b[pes_start_pos + 5]
      
      if(pes_stream_id >= 224 && pes_stream_id <= 239)	 #only video PIDs
        
        sync_bits = (b[pes_start_pos + 6] & 0xC0) >> 6
        puts "PES Sync error" unless sync_bits == 0x2
      
        dai = (b[pes_start_pos + 6] & 0x5) >> 2
        #puts "DAI not set" unless dai == 1
      
        pts_dts_flags = (b[pes_start_pos + 7] & 0xC0) >> 6
        pes_header_length = b[pes_start_pos + 8]
      
        if(pts_dts_flags ==  0x2 || pts_dts_flags == 0x3)
          pts = (((b[pes_start_pos + 9] & 0x0E) >> 1) << 30) | (b[pes_start_pos + 10] & 0xFF) << 22 | ((b[pes_start_pos + 11] & 0xFE) >> 1) << 15 | (b[pes_start_pos + 12] & 0xFF) << 7 | (b[pes_start_pos + 13] & 0xFE) >> 1
          #puts "PTS: #{pts*300}" unless pid.to_s(10) != @selected_pid
      
          if(pts_dts_flags == 0x3)
            dts = (((b[pes_start_pos + 14] & 0x0E) >> 1) << 30) | (b[pes_start_pos + 15] & 0xFF) << 22 | ((b[pes_start_pos + 16] & 0xFE) >> 1) << 15 | (b[pes_start_pos + 17] & 0xFF) << 7 | (b[pes_start_pos + 18] & 0xFE) >> 1
            #puts "DTS: #{dts*300}" unless pid.to_s(10) != @selected_pid
          elsif(pts_dts_flags == 0x2)
            dts = pts
          end
        end
          
        value = [dts*300, @pid_counter[pid]]
        @dts_pos_per_pid[pid].push value unless pid.to_s(10) != @selected_pid 
        
      end   
    end  #pes start code
  end #pes parsing
end


@selected_pid = ARGV[1] unless ARGV[1] == nil

File.open ARGV[0] do |file|    
  while not file.eof? do
  
    buffer = file.read MPEG2TS_BLOCK_SIZE
    
    #b_uint = 188 byte array
    b_uint = buffer.unpack 'C*'
    
    unless(b_uint[0] == 0x47)
      puts "TS Sync lost @ #{file.pos}"
      exit
    end
    
    @pusi = (((b_uint[1] & 0x40) >> 6)  == 1) ? 1 : 0
    pid =  ((b_uint[1] & 0x1f) << 8) | (b_uint[2] & 0xff)
    @pid_counter[pid] += 1; #increments pid occurence in hash table by 1 
    
    af_control = (b_uint[3] & 0x30) >> 4
    processAdaptationField b_uint, pid, af_control
   
    print "Processed ", @total_packet_count, " packets so far...", "\r" unless ((@total_packet_count % 100000 != 0) || (@total_packet_count == 0))
      
    @total_packet_count +=1 
  end
end

puts

@dts_pos_per_pid.keys.sort.each do |key| #loop per pid (key)
  @dts_pos_per_pid[key].each_with_index do |value, i| 
    #print key, "  ", @pcr_pos_per_pid[key][i][0], "  ", @pcr_pos_per_pid[key][i][1], "\n"
    dts = @dts_pos_per_pid[key][i][0]
    dts_ts_pkt_count = @dts_pos_per_pid[key][i][1]  
    @pcr_pos_per_pid[key].each_with_index do |value, j| 
      unless j == 0
        pcr = @pcr_pos_per_pid[key][j][0]
        prev_pcr = @pcr_pos_per_pid[key][j-1][0]
        pcr_ts_pkt_count = @pcr_pos_per_pid[key][j][1]
        prev_pcr_ts_pkt_count = @pcr_pos_per_pid[key][j-1][1]
        ts_bitrate = ((pcr_ts_pkt_count - prev_pcr_ts_pkt_count) * MPEG2TS_BLOCK_SIZE * 8 * CLOCKS_PER_SEC)/(pcr-prev_pcr)
        if(pcr > dts)
          delta = (pcr - dts) #time in 27Mhz ticks
          delta_bits = (delta * ts_bitrate)/CLOCKS_PER_SEC #convert to bits
          delta_packets = delta_bits/(8 * MPEG2TS_BLOCK_SIZE)
          vbv = (pcr_ts_pkt_count - dts_ts_pkt_count)*MPEG2TS_BLOCK_SIZE*8 - delta_bits
          #print (pcr_ts_pkt_count - delta_packets), ": PCR: ", pcr, "  ", dts_ts_pkt_count, ": DTS: ", dts, "  VBV: ", vbv , " bits", "  Delta bits: ", delta_bits,
          #" TS Bitrate: ", ts_bitrate, "\n"
          @plot_vbv_levels.push(vbv)
          break
        end 
      end #unless 
    end #per pcr
  end #per dts
end #per pid

#=begin
unless @plot_vbv_levels.size == 0
Gnuplot.open do |gp| 
Gnuplot::Plot.new( gp ) do |plot|
      
#plot.terminal "gif"
#plot.output "trunk_mod_.gif"
	  
plot.xrange "[0:#{@plot_vbv_levels.size}]"
plot.yrange "[#{@plot_vbv_levels.min}*0.9:#{@plot_vbv_levels.max}*1.1]"
plot.title  "VBV on PID #{@selected_pid}"
plot.ylabel "VBV"
plot.xlabel "Samples"
    
x = Array.new()
@plot_vbv_levels.each_with_index do |v,i|
x.push v 
end 
    
plot.data = [
Gnuplot::DataSet.new(x) { |ds|
ds.with = "lines"
ds.title = "VBV"
}
]
end
end
end
#=end
