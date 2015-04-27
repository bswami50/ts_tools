require 'fileutils'

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream

tspkt_count = 0;
tspkt_found = 0;

def processTSPacket buffer
  #puts buffer[0].to_s(16)  
end

f_write = File.open(ARGV[1], "w")

File.open ARGV[0] do |file|    
  while not file.eof? do
  
    buffer = file.read MPEG2TS_BLOCK_SIZE
    
    if buffer.length != MPEG2TS_BLOCK_SIZE
      print 'Wrong TS packet size at pos: ', file.pos, "\n"
    end  
    
    #b_uint = 188 byte array
    b_uint = buffer.unpack 'C*'
  
    if (tspkt_found == 0)  
      i=0
      while b_uint[i] != 0x47 
        i+=1                 
      end
      tspkt_found = 1;
      print "TS packet found at pos: ",  i, "\n"  
      file.seek(188+i)    
    elsif (b_uint[0] == 0x47) 
      tspkt_count += 1
      processTSPacket b_uint
      f_write << (b_uint.pack 'C*')
    else
      print "TS Lost Sync at pos: ", file.pos, "\n"  
      tspkt_found =0;
    end      
  end  
  print "Processed TS packet count: ", tspkt_count, "\n"  
end

f_write.close unless f_write == nil