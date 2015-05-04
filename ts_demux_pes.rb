require 'fileutils'

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream
CLOCKS_PER_SEC = 27000000

@pid_counter = Hash.new(0)
@f_write = Hash.new(0)
@total_packet_count = 0
@total_written_pes_packets = Hash.new(0)
@in_file = "in"
@out_base = "out"
@selected_pid = Array.new(0)
@pusi = 0

def processAdaptationField b, pid, af_control
  
  af_length = (af_control == 0x1) ? -1 : b[4]     #0x1 means payload only. There is no length byte so -1
  
  unless (af_length > 183)
    pes_start_pos = 4 + af_length + 1    

    b_pes = b
    b_pes = b_pes.drop(4+1+af_length) # 4 TS header bytes + 1 AF Length byte + AF Length
    @f_write[pid] << (b_pes.pack 'C*')  
    @total_written_pes_packets[pid] +=1 
  end 
end

t1 = Time.new()
if (ARGV[0]== nil) || (ARGV[1] == nil) || (!ARGV[1].match(/^[[:alpha:]]+$/)) || (ARGV[2] == nil) || (ARGV[0] == "-h")
  puts "Usage: ruby ts_demux_pes.rb TS_FILE OUT_FILE_BASE PID1 [PID2] ..."
  puts  "TS_FILE           Input TS beginning with proper start code (0x47)"
  puts  "OUT_FILE_BASE     Base filename of output. Note PID suffixes will be appended to base"
  puts  "PID1, PID2        PIDs (decimal) to be demuxed"
  puts
  exit
end


@in_file = ARGV.shift
@out_base = ARGV.shift 

while !ARGV.empty?
  pid =  ARGV.shift.to_i
  @selected_pid.push(pid) 
  @f_write[pid] = File.open("#{@out_base}_#{pid}.pes","w")
end

File.open @in_file do |file|    
  while not file.eof? do
  
    buffer = file.read MPEG2TS_BLOCK_SIZE
    
    #b_uint = 188 byte array
    b_uint = buffer.unpack 'C*'
    
    unless(b_uint[0] == 0x47)
      puts "TS Sync lost @ #{file.pos}. Please re-sync with ts_trim."
      exit
    end
    
    @pusi = (((b_uint[1] & 0x40) >> 6)  == 1) ? 1 : 0
    pid =  ((b_uint[1] & 0x1f) << 8) | (b_uint[2] & 0xff)
    @pid_counter[pid] += 1; #increments pid occurence in hash table by 1 
    
    af_control = (b_uint[3] & 0x30) >> 4
    processAdaptationField b_uint, pid, af_control unless (!@selected_pid.include? pid)
   
    print "Processed ", @total_packet_count, " packets so far...", "\r" unless ((@total_packet_count % 100000 != 0) || (@total_packet_count == 0))
      
    @total_packet_count +=1       
  end
end
t2=Time.new()

valid_pid_found = 0
@selected_pid.each do |pid|
  if(@total_written_pes_packets[pid] != 0)
    valid_pid_found = 1
    break
  end
end

    puts "No PES packets found on selected PIDs. Valid PIDs are: ", @pid_counter.keys.sort unless valid_pid_found == 1


@selected_pid.each do |pid|
  @f_write[pid].close()
  print "Demuxed ", @total_written_pes_packets[pid]," PES packets on PID #{pid} in ", t2-t1, "s", "\n"
end