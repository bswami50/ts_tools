require 'fileutils'

MPEG2TS_BLOCK_SIZE = 192  # block size for M2TS format

tspkt_count = 0;
tspkt_found = 0;

def processTSPacket buffer
  #puts buffer[0].to_s(16)  
end

pid_counter = Hash.new(0);
total_packet_count = 0;

t1 = Time.new()
f_write = File.open(ARGV[1], "w")
File.open ARGV[0] do |file|    
  while not file.eof? do
  
    buffer = file.read MPEG2TS_BLOCK_SIZE
    
    #b_uint = 192 byte array
    b_uint = buffer.unpack 'C*'
    timestamp = (b_uint[0] << 24) | (b_uint[1] << 16) | (b_uint[2] << 8) | (b_uint[3])     
    
    #remove timestamps
    b_uint.delete_at(0)
    b_uint.delete_at(0)
    b_uint.delete_at(0)
    b_uint.delete_at(0)
    
    if(b_uint[0] == 0x47)
    pid =  ((b_uint[1] & 0x1f) << 8) | (b_uint[2] & 0xff)
    pid_counter[pid] += 1; #increments pid occurence in hash table by 1 
    
    f_write << (b_uint.pack 'C*')
    total_packet_count +=1       
  end
    
    if(total_packet_count % 100000 == 0)
      print "TS Packets Processed: ", total_packet_count, "\r"
    end
    
  end
end
t2=Time.new()
  
  
print "\n", "PID hex (dec) :   Count", "\n"
pid_counter.keys.sort.each do |key|
  print "0x#{key.to_s(16)}".rjust(6), "(", key.to_s(10).rjust(5), ") : ", pid_counter[key].to_s.rjust(8), "\n"
end 

print "\n", "Elapsed: ", t2-t1, "s", "\n "