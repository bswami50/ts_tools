require 'fileutils'
require 'gnuplot'

MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream
CLOCKS_PER_SEC = 27000000

@pid_counter = Hash.new(0)
@total_packet_count = 0
@selected_pid = 0
@pusi = 0
@mp2_pic_types = {1.to_s=>'I', 2.to_s=>'P',3.to_s=>'B'}

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
     end
	end
  
  #PES parsing
  unless (af_length > 183 || @pusi == 0)
    pes_start_pos = 4 + af_length + 1    

	#demux PES 
	if(pid.to_s(10) == @selected_pid)
     b_pes = b
     b_pes = b_pes.drop(4+1+af_length) # 4 TS header bytes + 1 AF Length byte + AF Length
     @f_write << (b_pes.pack 'C*') unless (pid.to_s(10) != @selected_pid)
    end    
	
    pes_start_code = b[pes_start_pos] << 16 | b[pes_start_pos+1] << 8 | b[pes_start_pos+2] unless (af_length > 180)
    
    if(pes_start_code == 0x1)
      pes_stream_id = b[pes_start_pos + 3] #Ex for video, #Cx for audio
  
      pes_length = b[pes_start_pos + 4] << 8 | b[pes_start_pos + 5]
      
      sync_bits = (b[pes_start_pos + 6] & 0xC0) >> 6
      puts "PES Sync error" unless sync_bits == 0x2
      
      dai = (b[pes_start_pos + 6] & 0x5) >> 2
      #puts "DAI not set" unless dai == 1
      
      pts_dts_flags = (b[pes_start_pos + 7] & 0xC0) >> 6
      pes_header_length = b[pes_start_pos + 8]
      
      if(pts_dts_flags ==  0x2 || pts_dts_flags == 0x3)
        pts = (((b[pes_start_pos + 9] & 0x0E) >> 1) << 30) | (b[pes_start_pos + 10] & 0xFF) << 22 | ((b[pes_start_pos + 11] & 0xFE) >> 1) << 15 | (b[pes_start_pos + 12] & 0xFF) << 7 | (b[pes_start_pos + 13] & 0xFE) >> 1
        #puts "PTS: #{pts}" unless pid.to_s(10) != @selected_pid
      end
      
      if(pts_dts_flags == 0x3)
        dts = (((b[pes_start_pos + 14] & 0x0E) >> 1) << 30) | (b[pes_start_pos + 15] & 0xFF) << 22 | ((b[pes_start_pos + 16] & 0xFE) >> 1) << 15 | (b[pes_start_pos + 17] & 0xFF) << 7 | (b[pes_start_pos + 18] & 0xFE) >> 1
        #puts "DTS: #{dts}" unless pid.to_s(10) != @selected_pid
      end
      
      #ES parsing
      if(pid.to_s(10) == @selected_pid)
        
        es_start_pos = pes_start_pos + 8 + pes_header_length + 1    
        es_start_code_prefix = b[es_start_pos] << 16 | b[es_start_pos+1] << 8 | b[es_start_pos+2] 
        print "ES Start code prefix error #{es_start_code_prefix} \n"  unless es_start_code_prefix == 0x1 || es_start_code_prefix == 0x0 
        es_start_code = b[es_start_pos+3]
        
        #this needs to be in a loop
        if((es_start_code_prefix << 24| es_start_code) == 0x1) #4-byte start code
          if(b[es_start_pos + 4] == 0x9) #AUD (skip it)
            es_start_pos += 6
            es_start_code_prefix = b[es_start_pos] << 16 | b[es_start_pos+1] << 8 | b[es_start_pos+2] 
            print "ES Start code prefix error #{es_start_code_prefix} \n"  unless es_start_code_prefix == 0x1 || es_start_code_prefix == 0x0 
            es_start_code = b[es_start_pos+3]
            
            if((es_start_code_prefix << 24| es_start_code) == 0x1)
              es_start_code = b[es_start_pos + 4] & 0x1f
            end          
          end
        end
        
        case es_start_code.to_s(16)
        when "b3"
          puts "MPEG-2 Sequence Header"
          print "Picture Size: ", (b[es_start_pos+4] << 8 | b[es_start_pos+5] & 0xf0) >> 4, "x",
          ((b[es_start_pos+5] & 0x0f) << 8 | b[es_start_pos+6]), "\n"
        when "0"
          puts "MPEG-2 Picture Header"
          print "Pic Type: ", @mp2_pic_types[((b[es_start_pos+5] & 0x38) >> 3).to_s], "\n"
        when "1"
          puts "AVC non-IDR slice @ #{@total_packet_count}*MPEG2TS_BLOCK_SIZE"
        when "5"
          puts "AVC IDR slice"
        when "6"
          puts "SEI @ #{@total_packet_count*MPEG2TS_BLOCK_SIZE}"
          puts "NAL forbidden bit not set! " unless ((b[es_start_pos + 4] & 0x80) >> 7 == 0)
          puts "NAL ref_idc non zero in SEI " unless ((b[es_start_pos + 4] & 0x60) >> 5 == 0)
        when "7"
          puts "SPS @ #{@total_packet_count*MPEG2TS_BLOCK_SIZE}"
          puts "NAL forbidden bit not set! " unless ((b[es_start_pos + 4] & 0x80) >> 7 == 0)
          puts "NAL ref_idc zero in SPS " unless ((b[es_start_pos + 4] & 0x60) >> 5 != 0)
          #print "Profile: ", b[es_start_pos + 5], "\n"
        when "8"
          puts "PPS @ #{@total_packet_count*MPEG2TS_BLOCK_SIZE}"  
          puts "NAL forbidden bit not set! " unless ((b[es_start_pos + 4] & 0x80) >> 7 == 0)
          puts "NAL ref_idc zero in PPS " unless ((b[es_start_pos + 4] & 0x60) >> 5 != 0)
          
        when "9"
          puts "AUD"
        else
          print "Other start code", es_start_code.to_s(16),"\n"
        end 
        #print "[#{pid}] 0x", es_start_code.to_s(16), "\n"
      end     
    end  #pes start code
  end #pes parsing
end

t1 = Time.new()
@selected_pid = ARGV[1] unless ARGV[1] == nil
@f_write = File.open("tmp.pes","w")

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
   
    #print "Processed ", @total_packet_count, " packets so far...", "\r" unless ((@total_packet_count % 100000 != 0) || (@total_packet_count == 0))
      
    @total_packet_count +=1       
  end
end
t2=Time.new()
@f_write.close()


print "\n", "Processed ", @total_packet_count, " packets in ", t2-t1, "s", "\n\n"