require 'fileutils'
require 'gnuplot'

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream
CLOCKS_PER_SEC = 27000000

@pid_counter = Hash.new(0)
@pcr_pid_counter = Hash.new(0)
@pcr_val_pos_per_pid = Hash.new{|hsh,key| hsh[key] = [] }
@total_packet_count = 0
@ref_pcr_pid = 0
@plot_pid = 0
@plot_pid_bitrates = Array.new()
@max_packets = 0

def processAdaptationField b, pid
  af_length = b[4]     
 
  if(af_length > 0)    
    pcr_flag = (b[5] & 0x10) >> 4
  
    if(pcr_flag == 0x1)
      pcr_base = (b[6]) << 25 | (b[7] << 17) | (b[8] << 9) | (b[9] << 1) | (b[10] & 80)
      pcr_extension = ((b[10] & 0x1) << 8) | b[11]    
      pcr = pcr_base * 300 + pcr_extension 
      
      @pcr_pid_counter[pid] += 1
      
      #save first seen pcr pid as reference unless specified
      @ref_pcr_pid = pid unless @ref_pcr_pid != 0 
      
      #print "PCR found at pos: ", @total_packet_count * 188," PCR: ", pcr, "\n" unless pid!=@ref_pcr_pid
      
      #when ref pid is found, update all counters for ALL pids
      if(pid == @ref_pcr_pid) 
        @pid_counter.keys.sort.each do |key|
          @pcr_val_pos_per_pid[key].push [pcr, @pid_counter[key], @total_packet_count]
        end        
      end   
    end
  end
end

#Program start

t1 = Time.new()
if (ARGV[0]== nil) || (ARGV[0] == "-h")
puts "Usage: ruby ts_find_pid.rb TS FILE [PID] [MAX_PACKETS]"
puts  "TS FILE           TS beginning with proper start code (0x47)"
puts  "[PID]             PID (decimal) to plot bitrate (default=none)"
puts  "[PCR]             Use this PID (decimal) as PCR for timing (default=first found PCR PID)"
puts  "[MAX PACKETS]     Process only these #packets (default=-1 i.e. all packets)" 
exit
end

@plot_pid = ARGV[1].to_i unless ARGV[1] == nil
@ref_pcr_pid = ARGV[2].to_i unless ARGV[2] == nil
@max_packets = ARGV[3].to_i unless ARGV[3] == nil

File.open ARGV[0] do |file|    
  while not file.eof? do
    buffer = file.read MPEG2TS_BLOCK_SIZE
    
    #b_uint = 188 byte array
    b_uint = buffer.unpack 'C*'
     
    pid =  ((b_uint[1] & 0x1f) << 8) | (b_uint[2] & 0xff)
    @pid_counter[pid] += 1; #increments pid occurence in hash table by 1 
    
    af_control = (b_uint[3] & 0x30) >> 4
    if(af_control == 0x2 || af_control == 0x3)
      processAdaptationField b_uint, pid
    end
    
    #status print
    print "Processed ", @total_packet_count, " packets so far...", "\r" unless ((@total_packet_count % 100000 != 0) || (@total_packet_count == 0))
      
    @total_packet_count +=1       
	
	#process max packets
	if((@total_packet_count > @max_packets) && (@max_packets!=0))
	 break
	end
	
  end
end
t2=Time.new()
     
puts 

#check if passed plot PID is valid
unless (@pid_counter.keys.include? @plot_pid)
puts "Wrong Plot PID: #{@plot_pid}. Valid ones are:"
puts @pid_counter.keys.sort
exit
end

#check if passed PCR PID is valid
unless (@pcr_pid_counter.keys.include? @ref_pcr_pid)
puts "Wrong PCR PID: #{@ref_pcr_pid}. Valid ones are:"
puts @pcr_pid_counter.keys.sort
exit
end

print "\nCalculating bitrates using ref PCR PID: 0x", @ref_pcr_pid.to_s(16), "(", @ref_pcr_pid.to_s(10).rjust(4),")","\n"
 
#print unique pids and their count  
print "\n", "-------------------------------------- \n"
print       "|PID hex (dec) |  Count  |   Bitrate  |", "\n"
print       "-------------------------------------- \n"
 
#process all pids and print bitrate
sum_ts_bitrate = 0
sum_ts_packets = 0
  
@pcr_val_pos_per_pid.keys.sort.each do |key| #loop per pid (key)
  sum_pid_bitrate = 0
  @pcr_val_pos_per_pid[key].each_with_index do |value, i|    
    curr_pcr           = @pcr_val_pos_per_pid[key][i][0] #value[0] = pcr 
    curr_pkt_pos_pid   = @pcr_val_pos_per_pid[key][i][1] #value[1] = pid_ts_pkt_pos
    curr_pkt_pos_total = @pcr_val_pos_per_pid[key][i][2] #value[2] = total_ts_pkt_pos
    unless i == 0
      prev_pcr           = @pcr_val_pos_per_pid[key][i-1][0] 
      prev_pkt_pos_pid   = @pcr_val_pos_per_pid[key][i-1][1] 
      prev_pkt_pos_total = @pcr_val_pos_per_pid[key][i-1][2] 
      pcr_delta          = curr_pcr - prev_pcr 
      pid_pkt_delta      = curr_pkt_pos_pid - prev_pkt_pos_pid
      total_pkt_delta    = curr_pkt_pos_total - prev_pkt_pos_total
      if(pcr_delta > 0)          
        pid_bitrate    = CLOCKS_PER_SEC * (pid_pkt_delta   * 8 * MPEG2TS_BLOCK_SIZE) / (pcr_delta)  
          
        if((key.to_i == @plot_pid) && (@plot_pid!=0))
          @plot_pid_bitrates.push(pid_bitrate)
		  #print "PID: 0x#{key.to_s(16)}".rjust(6), "  ", pid_bitrate.to_s.rjust(8), "  " ,(pcr_delta/27000).round(4).to_s.rjust(8), "\n" 
        end
          
        total_ts_bitrate  = CLOCKS_PER_SEC * (total_pkt_delta * 8 * MPEG2TS_BLOCK_SIZE) / (pcr_delta) 
        sum_pid_bitrate += pid_bitrate 
        sum_ts_bitrate += total_ts_bitrate 
        sum_ts_packets += 1 
      end
     end    
  end
  print "0x#{key.to_s(16)}".rjust(6), "(", key.to_s(10).rjust(5),") : ", @pid_counter[key].to_s.rjust(8), "   ", 
  ((sum_pid_bitrate/@pcr_val_pos_per_pid[key].size).to_f/1000000).round(3).to_s.rjust(6), " Mb/s" 
  print " (PCR)" unless @pcr_pid_counter[key] == 0
  print "\n"
end   

unless @plot_pid_bitrates.size == 0
  Gnuplot.open do |gp| 
    Gnuplot::Plot.new( gp ) do |plot|
      
      plot.xrange "[0:#{@plot_pid_bitrates.size}]"
      plot.yrange "[#{@plot_pid_bitrates.min}*0.9:#{@plot_pid_bitrates.max}*1.1]"
	  plot.title  "Bitrate on PID #{@plot_pid}"
      plot.ylabel "Bitrate"
      plot.xlabel "Samples"
    
      x = Array.new()
      @plot_pid_bitrates.each_with_index do |v,i|
        x.push v 
      end 
    
      plot.data = [
        Gnuplot::DataSet.new(x) { |ds|
          ds.with = "lines"
          ds.title = "Bitrate"
        }
      ]
    end
  end
end

print "\n", "Total TS Bitrate: ", (sum_ts_bitrate/sum_ts_packets).to_f/1000000, " Mb/s", "\n"

print "\n", "Processed ", @total_packet_count, " packets in ", t2-t1, "s", "\n\n"