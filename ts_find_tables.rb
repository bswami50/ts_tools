MPEG2TS_BLOCK_SIZE = 188  # block size for transport stream
CLOCKS_PER_SEC = 27000000

@pid_counter = Hash.new(0)
@pusi = 0
@total_packet_count = 0
@program_map_pids = Hash.new(0)
@network_pid = 0
@program_info = Hash.new{|hsh,key| hsh[key] = [] }

MPEG_STREAM_TYPES={
  0x00 => "ITU-T | ISO/IEC Reserved",
  0x01 => "ISO/IEC 11172-2 Video",
  0x02 => "MPEG-2 Video",
  0x03 => "ISO/IEC 11172-3 Audio",
  0x04 => "ISO/IEC 13818-3 Audio",
  0x05 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 private_sections",
  0x06 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 PES packets containing private data",
  0x07 => "ISO/IEC 13522 MHEG",
  0x08 => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 Annex A DSM-CC",
  0x09 => "ITU-T Rec. H.222.1",
  0x0A => "ISO/IEC 13818-6 type A",
  0x0B => "ISO/IEC 13818-6 type B",
  0x0C => "ISO/IEC 13818-6 type C",
  0x0D => "ISO/IEC 13818-6 type D",
  0x0E => "ITU-T Rec. H.222.0 | ISO/IEC 13818-1 auxiliary",
  0x0F => "ISO/IEC 13818-7 Audio with ADTS transport syntax",
  0x10 => "ISO/IEC 14496-2 Visual",
  0x11 => "ISO/IEC 14496-3 Audio with the LATM transport syntax as defined in ISO/IEC 14496-3",
  0x12 => "ISO/IEC 14496-1 SL-packetized stream or FlexMux stream carried in PES packets",
  0x13 => "ISO/IEC 14496-1 SL-packetized stream or FlexMux stream carried in ISO/IEC 14496_sections",
  0x14 => "ISO/IEC 13818-6 Synchronized Download Protocol",
  0x15 => "Metadata carried in PES packets",
  0x16 => "Metadata carried in metadata_sections",
  0x17 => "Metadata carried in ISO/IEC 13818-6 Data Carousel",
  0x18 => "Metadata carried in ISO/IEC 13818-6 Object Carousel",
  0x19 => "Metadata carried in ISO/IEC 13818-6 Synchronized Download Protocol",
  0x1A => "IPMP stream (defined in ISO/IEC 13818-11, MPEG-2 IPMP)",
  0x1B => "AVC/H.264 video stream",
  0x7F => "IPMP stream",
  0x81 => "A52/AC-3 Audio"
}

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
    
    if((pid == 0) && (@pusi == 1))    #PAT 
      af_control = (b_uint[3] & 0x30) >> 4
      af_length = (af_control == 0x1) ? -1 : b[4]     #0x1 means payload only. There is no length byte so -1
      pat_start_offset = 4 + af_length + 1 + 1        #+1 to read past "pointer" byte
    
      table_id = b_uint[pat_start_offset]
      puts "Wrong Table ID" unless table_id == 0
      section_syntax_indicator = (b_uint[pat_start_offset + 1] & 0x80) >> 7
      puts "Section Syntax Indicator wrong" unless section_syntax_indicator == 1
      section_length = ((b_uint[pat_start_offset+1] & 0x0f) << 8) | b_uint[pat_start_offset+2]
      ts_id = (b_uint[pat_start_offset+3] << 8) | b_uint[pat_start_offset+4]
      #skip 3 bytes here
      program_length = section_length - 5 - 4 #5 bytes before program info and 4 CRC bytes
      num_programs = program_length/4 #4 bytes for each program info
      puts "Wrong section length or bad program info" unless (program_length % 4) == 0
    
      program_info_start_offset = pat_start_offset + 8
      for i in (0..num_programs-1)
        program_number = (b_uint[program_info_start_offset + 4*i] << 8) | b_uint[program_info_start_offset + 4*i + 1]
        program_map_pid =  ((b_uint[program_info_start_offset + 4*i + 2] & 0x1f) << 8) | b_uint[program_info_start_offset + 4*i + 3]
        if(program_number == 0)
          @network_pid = program_map_pid #NIT PID with private data
        end
        
        @program_map_pids[program_map_pid] = program_number unless ((@program_map_pids.include? program_map_pid) || (program_number == 0)) #save program pids   
           
      end
    elsif ((@program_map_pids.include? pid) && (@pusi == 1))     #PMT
      af_control = (b_uint[3] & 0x30) >> 4
      af_length = (af_control == 0x1) ? -1 : b[4]     #0x1 means payload only. There is no length byte so -1
      pmt_start_offset = 4 + af_length + 1 + 1        #+1 to read past "pointer" byte
    
      table_id = b_uint[pmt_start_offset]
      puts "PMT PID: #{pid} Unsupported Table ID: #{table_id}" unless table_id == 2
    
      if(table_id == 2)
        section_syntax_indicator = (b_uint[pmt_start_offset + 1] & 0x80) >> 7
        puts "Section Syntax Indicator wrong" unless section_syntax_indicator == 1
        section_length = ((b_uint[pmt_start_offset+1] & 0x0f) << 8) | b_uint[pmt_start_offset+2]
        program_number = (b_uint[pmt_start_offset+3] << 8) | b_uint[pmt_start_offset+4]
        #skip 3 bytes here
        pcr_pid = ((b_uint[pmt_start_offset+8] & 0x1f) << 8) | b_uint[pmt_start_offset+9]
        program_info_length = ((b_uint[pmt_start_offset+10] & 0x0f) << 8) | b_uint[pmt_start_offset+11]  
        #skip over program descriptors
    
        es_info_offset = 12 + program_info_length
    
        while ((es_info_offset + 5 + 4 - 3) < section_length)    #need min 5 bytes for es_info, 4 bytes for CRC and 3 is offset of section length
          stream_type = b_uint[es_info_offset]
          reserved1 = (b_uint[es_info_offset + 1] & 0xE0) >> 5

          #Parse only if reserved fields are valid
          if (reserved1 == 0x7)
            es_pid = ((b_uint[es_info_offset+1] & 0x1f) << 8) | b_uint[es_info_offset+2]     
            reserved2 = (b_uint[es_info_offset + 3] & 0xF0) >> 4
            if (reserved2 == 0xf)
              es_info_length = ((b_uint[es_info_offset+3] & 0x0f) << 8) | b_uint[es_info_offset+4]
              #skip over es descriptors
              es_info_offset += es_info_length
              value = [pcr_pid, es_pid, stream_type]
              @program_info[pid].push value unless (@program_info[pid].include? value) #only push unique entries
            end #reserved2
          end #reserved1                    
          es_info_offset += 5 #minimum size of ES Info section                           
        end #es info parsing
      end #table_id check
    end     
    @total_packet_count +=1  
    print "Processed ", @total_packet_count, " packets so far...", "\r" unless ((@total_packet_count % 100000 != 0) || (@total_packet_count == 0))     
  end
end

puts 
@program_info.keys.sort.each do |key| 
  @program_info[key].each_with_index do |value, i|
    print "Program #: ", @program_map_pids[key], "  PMT: ", key.to_s(10).rjust(5), "  PCR: ", @program_info[key][i][0].to_s(10).rjust(5), "   ES: ", @program_info[key][i][1].to_s(10).rjust(5), 
    "   Type: 0x", @program_info[key][i][2].to_s(16).ljust(4), "  ", MPEG_STREAM_TYPES[@program_info[key][i][2]], "\n"
  end
  puts
end
 
 
