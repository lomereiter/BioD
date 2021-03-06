/*
    This file is part of BioD.
    Copyright (C) 2012    Artem Tarasov <lomereiter@gmail.com>

    BioD is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    BioD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/
module bio.bam.read;

import bio.core.base;

import bio.bam.writer;
import bio.bam.tagvalue;
import bio.bam.bai.bin;

import bio.bam.utils.array;
import bio.bam.utils.value;
import bio.core.utils.switchendianness;

import bio.bam.thirdparty.msgpack : Packer, unpack;

version(unittest) {
    import bio.bam.utils.tagstoragebuilder;
    import std.stdio;
}

import std.algorithm;
import std.range;
import std.conv;
import std.exception;
import std.system;
import std.traits;
import std.array;

/**
  Represents single CIGAR operation
 */
struct CigarOperation {
    static assert(CigarOperation.sizeof == uint.sizeof);
    /*
        WARNING!

      It is very essential that the size of 
      this struct is EXACTLY equal to uint.sizeof!

      The reason is to avoid copying of arrays during alignment parsing.

      Namely, when some_pointer points to raw cigar data,
      we can just do a cast. This allows to access those data
      directly, not doing any memory allocations. 
    */

    private uint raw; // raw data from BAM

    private static ubyte char2op(char c) {
        switch(c) {
            case 'M': return 0;
            case 'I': return 1;
            case 'D': return 2;
            case 'N': return 3;
            case 'S': return 4;
            case 'H': return 5;
            case 'P': return 6;
            case '=': return 7;
            case 'X': return 8;
            default:  return 15; // 15 is used as invalid value
        }
    }

    this(uint length, char operation_type) {
        enforce(length < (1<<28), "Too big length of CIGAR operation");
        raw = (length << 4) | char2op(operation_type);
    }

    /// operation length
    uint length() @property const nothrow {
        return raw >> 4;
    }
  
    /// CIGAR operation as one of MIDNSHP=X.
    /// Absent or invalid operation is represented by '?'
    char type() @property const nothrow {
        return "MIDNSHP=X????????"[raw & 0xF];
    }

    // Each pair of bits has first bit set iff the operation is query consuming,
    // and second bit set iff it is reference consuming.
    //                                            X  =  P  H  S  N  D  I  M
    private static immutable uint CIGAR_TYPE = 0b11_11_00_00_01_10_10_01_11;

    /// True iff operation is one of M, =, X, I, S
    bool is_query_consuming() @property const {
        return ((CIGAR_TYPE >> ((raw & 0xF) * 2)) & 1) != 0;
    }

    /// True iff operation is one of M, =, X, D, N
    bool is_reference_consuming() @property const {
        return ((CIGAR_TYPE >> ((raw & 0xF) * 2)) & 2) != 0;
    }

    /// True iff operation is one of M, =, X
    bool is_match_or_mismatch() @property const {
        return ((CIGAR_TYPE >> ((raw & 0xF) * 2)) & 3) == 3;
    }

    string toString() const {
        return to!string(length) ~ type;
    }
}

/** 
  Represents single read
*/
struct BamRead {

    mixin TagStorage;

    /// Reference index in BAM file header
    @property    int ref_id()           const nothrow { return _refID; }
    /// ditto
    @property   void ref_id(int n)                    { _dup(); _refID = n; }

    /// 0-based leftmost coordinate of the first matching base
    @property    int position()         const nothrow { return _pos; }
    /// ditto
    @property   void position(int n)                  { _dup(); _pos = n; _recalculate_bin(); }

    /// Indexing bin which this read belongs to. Recalculated when position is changed.
    @property    Bin bin()              const nothrow { return Bin(_bin); }

    /// Mapping quality. Equals to 255 if not available, otherwise
    /// equals to rounded -10 * log10(P {mapping position is wrong}).
    @property  ubyte mapping_quality()  const nothrow { return _mapq; }
    /// ditto
    @property   void mapping_quality(ubyte n)         { _dup(); _mapq = n; }

    /// Flag bits (should be used on very rare occasions, see flag getters/setters below)
    @property ushort flag()             const nothrow { return _flag; }
    /// ditto
    @property   void flag(ushort n)                   { _dup(); _flag = n; }

    /// Sequence length. In fact, sequence.length can be used instead, but that might be
    /// slower if the compiler is not smart enough to optimize away unrelated stuff.
    @property    int sequence_length()  const nothrow { return _l_seq; }

    /// Mate reference ID
    @property    int mate_ref_id()      const nothrow { return _next_refID; }
    /// ditto
    @property   void mate_ref_id(int n)               { _dup(); _next_refID = n; }

    /// Mate position
    @property    int mate_position()    const nothrow { return _next_pos; }
    /// ditto
    @property   void mate_position(int n)             { _dup(); _next_pos = n; }

    /// Template length
    @property    int template_length()  const nothrow { return _tlen; }
    /// ditto
    @property   void template_length(int n)           { _dup(); _tlen = n; }

    // ------------------------ FLAG GETTERS/SETTERS -------------------------------------- //

    /// Template having multiple segments in sequencing
    @property bool is_paired()                const nothrow { return cast(bool)(flag & 0x1); }
    /// ditto
    @property void is_paired(bool b)                { _setFlag( 0, b); }

    /// Each segment properly aligned according to the aligner
    @property bool proper_pair()              const nothrow { return cast(bool)(flag & 0x2); }
    /// ditto
    @property void proper_pair(bool b)              { _setFlag( 1, b); }

    /// Segment unmapped
    @property bool is_unmapped()              const nothrow { return cast(bool)(flag & 0x4); }
    /// ditto
    @property void is_unmapped(bool b)              { _setFlag( 2, b); }

    /// Next segment in the template unmapped
    @property bool mate_is_unmapped()         const nothrow { return cast(bool)(flag & 0x8); }
    /// ditto
    @property void mate_is_unmapped(bool b)         { _setFlag( 3, b); } 

    /// Sequence being reverse complemented
    @property bool is_reverse_strand()        const nothrow { return cast(bool)(flag & 0x10); }
    /// ditto
    @property void is_reverse_strand(bool b)        { _setFlag( 4, b); } 

    /// Sequence of the next segment in the template being reversed
    @property bool mate_is_reverse_strand()   const nothrow { return cast(bool)(flag & 0x20); }
    /// ditto
    @property void mate_is_reverse_strand(bool b)   { _setFlag( 5, b); } 

    /// The first segment in the template
    @property bool is_first_of_pair()         const nothrow { return cast(bool)(flag & 0x40); }
    /// ditto
    @property void is_first_of_pair(bool b)         { _setFlag( 6, b); } 

    /// The last segment in the template
    @property bool is_second_of_pair()        const nothrow { return cast(bool)(flag & 0x80); }
    /// ditto
    @property void is_second_of_pair(bool b)        { _setFlag( 7, b); } 

    /// Secondary alignment
    @property bool is_secondary_alignment()   const nothrow { return cast(bool)(flag & 0x100); }
    /// ditto
    @property void is_secondary_alignment(bool b)   { _setFlag( 8, b); } 

    /// Not passing quality controls
    @property bool failed_quality_control()   const nothrow { return cast(bool)(flag & 0x200); }
    /// ditto
    @property void failed_quality_control(bool b)   { _setFlag( 9, b); } 

    /// PCR or optical duplicate
    @property bool is_duplicate()             const nothrow { return cast(bool)(flag & 0x400); }
    /// ditto
    @property void is_duplicate(bool b)             { _setFlag(10, b); } 


    /// Convenience function, returns '+' or '-' indicating the strand.
    @property char strand() const nothrow {
        return is_reverse_strand ? '-' : '+';
    }

    /// ditto
    @property void strand(char c) {
        enforce(c == '-' || c == '+', "Strand must be '-' or '+'");
        is_reverse_strand = c == '-';
    }


    /// Read name
    @property string name() const nothrow {
        // notice -1: the string is zero-terminated, so we should strip that '\0'
        return cast(string)(_chunk[_read_name_offset .. _read_name_offset + _l_read_name - 1]);
    }

    /// ditto
    @property void name(string new_name) {
        enforce(new_name.length >= 1 && new_name.length <= 255, 
                "name length must be in 1-255 range");
        _dup();
        bio.bam.utils.array.replaceSlice(_chunk, 
                 _chunk[_read_name_offset .. _read_name_offset + _l_read_name - 1],
                 cast(ubyte[])new_name);
        _l_read_name = cast(ubyte)(new_name.length + 1);
    }

    /// List of CIGAR operations
    @property const(CigarOperation)[] cigar() const nothrow {
        return cast(const(CigarOperation)[])(_chunk[_cigar_offset .. _cigar_offset + 
                                             _n_cigar_op * CigarOperation.sizeof]);
    }

    /// ditto
    @property void cigar(const(CigarOperation)[] c) {
        _dup();
        bio.bam.utils.array.replaceSlice(_chunk,
             _chunk[_cigar_offset .. _cigar_offset + _n_cigar_op * CigarOperation.sizeof],
             cast(ubyte[])c);

        _n_cigar_op = cast(ushort)(c.length);

        _recalculate_bin();
    }

    /// The number of reference bases covered
    int basesCovered() const {

        if (this.is_unmapped) {
            return 0; // actually, valid alignments should have empty cigar string
        }

        return reduce!"a + b.length"(0, filter!"a.is_reference_consuming"(cigar));
    }

    /// Human-readable representation of CIGAR string
    string cigarString() const {
        char[] str;

        // guess size of resulting string
        str.reserve(_n_cigar_op * 3);

        foreach (cigar_op; cigar) {
            str ~= to!string(cigar_op.length);
            str ~= cigar_op.type;
        }
        return cast(string)str;
    }

    private @property const(ubyte)[] raw_sequence_data() const nothrow {
        return _chunk[_seq_offset .. _seq_offset + (_l_seq + 1) / 2];
    }

    static struct SequenceResult {

        private size_t _index;
        private ubyte[] _data = void;
        private size_t _len = void;
        private bool _use_first_4_bits = void;

        this(const(ubyte[]) data, size_t len, bool use_first_4_bits=true) {
            _data = cast(ubyte[])data;
            _len = len;
            _use_first_4_bits = use_first_4_bits;
        }

        @property bool empty() const {
            return _index >= _len;
        }

        @property Base front() const {
            return opIndex(0);
        }

        @property Base back() const {
            return opIndex(_len - 1);
        }

        /* 
        I have no fucking idea why this tiny piece of code
        does NOT get inlined by stupid DMD compiler.

        Therefore I use string mixin instead. 
        (hell yeah! Back to the 90s! C macros rulez!)

        private size_t _getActualPosition(size_t index) const
        {
            if (_use_first_4_bits) {
                // [0 1] [2 3] [4 5] [6 7] ...
                //            |               
                //            V               
                //   0     1     2     3      
                return index >> 1;
            } else {
                // [. 0] [1 2] [3 4] [5 6] ...
                //            |               
                //            V               
                //   0     1     2     3      
                return (index >> 1) + (index & 1);
            }
        }*/ 

        private static string _getActualPosition(string index) {
            return "((" ~ index ~") >> 1) + " ~ 
                   "(_use_first_4_bits ? 0 : ((" ~ index ~ ") & 1))";
        }

        private bool _useFirst4Bits(size_t index) const
        {
            auto res = index % 2 == 0;
            if (!_use_first_4_bits) {
                res = !res;
            }
            return res;
        }

        @property SequenceResult save() const {
            return SequenceResult(_data[mixin(_getActualPosition("_index")) .. $], 
                                  _len - _index, 
                                  _useFirst4Bits(_index));
        }

        SequenceResult opSlice(size_t i, size_t j) const {
            return SequenceResult(_data[mixin(_getActualPosition("_index + i")) .. $], 
                                  j - i, 
                                  _useFirst4Bits(_index + i));
        }

        @property Base opIndex(size_t i) const {

            auto pos = _index + i;

            if (_use_first_4_bits)
            {
                if (pos & 1)
                    return Base.fromInternalCode(_data[pos >> 1] & 0xF);
                else
                    return Base.fromInternalCode(_data[pos >> 1] >> 4);
            }
            else
            {
                if (pos & 1)
                    return Base.fromInternalCode(_data[(pos >> 1) + 1] >> 4);
                else
                    return Base.fromInternalCode(_data[pos >> 1] & 0xF);
            }

            assert(false);
        }

        void popFront() {
            ++_index;
        }

        void popBack() {
            --_len;
        }

        @property size_t length() const {
            return _len - _index;
        }
    }

    /// Random-access range of characters
    @property auto sequence() const {
        return SequenceResult(raw_sequence_data, sequence_length);
    }

    static assert(isRandomAccessRange!(ReturnType!sequence));

    /// Set sequence. Must be of the same length as current sequence.
    @property void sequence(string seq) 
    {
        enforce(seq.length == _l_seq, "Sequence must have the same length as current");

        _dup();

        auto _raw_length = (seq.length + 1) / 2;
        // set sequence
        ubyte[] _seq = _chunk[_seq_offset .. _seq_offset + _raw_length];
        for (size_t i = 0; i < _raw_length; ++i) {
            _seq[i] = cast(ubyte)(Base(seq[2 * i]).internal_code << 4);

            if (seq.length > 2 * i + 1)
                _seq[i] |= cast(ubyte)(Base(seq[2 * i + 1]).internal_code);
        }
    }

    /// Quality data
    @property const(ubyte)[] base_qualities() const nothrow {
        return _chunk[_qual_offset .. _qual_offset + _l_seq * char.sizeof];
    }

    /// Set quality data - array length must be of the same length as the sequence.
    @property void base_qualities(const(ubyte)[] quality) {
        enforce(quality.length == _l_seq, "Quality data must be of the same length as sequence");
        _dup();
        _chunk[_qual_offset .. _qual_offset + _l_seq] = quality;
    }

    /**
      Constructs the struct from memory chunk
      */
    this(ubyte[] chunk) {

        // Switching endianness lazily is not a good idea:
        //
        // 1) switching byte order is pretty fast
        // 2) lazy switching for arrays can kill the performance,
        //    it has to be done once
        // 3) the code will be too complicated, whereas there're
        //    not so many users of big-endian systems
        //
        // In summa, BAM is little-endian format, so big-endian 
        // users will suffer anyway, it's unavoidable.

        this._is_slice = true;

        _chunk = chunk;
        if (std.system.endian != Endian.littleEndian) {
            switchChunkEndianness();

            // Dealing with tags is the responsibility of TagStorage.
            fixTagStorageByteOrder();
        }
    } 

    // Doesn't touch tags, only fields. 
    // @@@TODO: NEEDS TESTING@@@
    private void switchChunkEndianness() {
        // First 8 fields are 32-bit integers:                 
        //                                                     
        // 0) refID                int                         
        // 1) pos                  int                         
        // 2) bin_mq_nl           uint                         
        // 3) flag_nc             uint                         
        // 4) l_seq                int                         
        // 5) next_refID           int                         
        // 6) next_pos             int                         
        // 7) tlen                 int                         
        // ----------------------------------------------------
        // (after them name follows which is string)      
        //                                                     
        switchEndianness(_chunk.ptr, 8 * uint.sizeof);

        // Then we need to switch endianness of CIGAR data:
        switchEndianness(_chunk.ptr + _cigar_offset, 
                         _n_cigar_op * uint.sizeof);
    }
 
    private size_t calculateChunkSize(string read_name, 
                                      string sequence, 
                                      in CigarOperation[] cigar)
    {
        return 8 * int.sizeof
                 + (read_name.length + 1) // tailing '\0'
                 + uint.sizeof * cigar.length
                 + ubyte.sizeof * ((sequence.length + 1) / 2)
                 + ubyte.sizeof * sequence.length;
    }

    /// Construct alignment from basic information about it.
    ///
    /// Other fields can be set afterwards.
    this(string read_name,                          // info for developers:
         string sequence,                           // these 3 fields are needed
         in CigarOperation[] cigar)                 // to calculate size of _chunk
    {
        enforce(read_name.length < 256, "Too long read name, length must be <= 255");

        this._is_slice = false;

        if (this._chunk is null) {
            this._chunk = new ubyte[calculateChunkSize(read_name, sequence, cigar)];
        }
        
        this._refID      =  -1;         // set default values
        this._pos        =  -1;         // according to SAM/BAM
        this._mapq       = 255;         // specification
        this._next_refID =  -1;
        this._next_pos   =  -1;
        this._tlen       =   0;

        this._l_read_name = cast(ubyte)(read_name.length + 1); // tailing '\0'
        this._n_cigar_op  = cast(ushort)(cigar.length);
        this._l_seq       = cast(int)(sequence.length);

        // now all offsets can be calculated through corresponding properties

        // set default quality
        _chunk[_qual_offset .. _qual_offset + sequence.length] = 0xFF;

        // set CIGAR data
        auto _len = cigar.length * CigarOperation.sizeof;
        _chunk[_cigar_offset .. _cigar_offset + _len] = cast(ubyte[])(cigar);

        // set read_name
        auto _offset = _read_name_offset;
        _chunk[_offset .. _offset + read_name.length] = cast(ubyte[])read_name;
        _chunk[_offset + read_name.length] = cast(ubyte)'\0';

        this.sequence = sequence;
    }

    /// Low-level constructor for setting tag data on construction.
    /// This allows to use less reallocations when creating an alignment
    /// from scratch, by reusing memory for collecting tags.
    /// Typically, you would use this constructor in conjunction with
    /// utils.tagstoragebuilder module.
    this(string read_name, 
         string sequence, 
         in CigarOperation[] cigar, 
         in ubyte[] tag_data)
    {
        _chunk = new ubyte[calculateChunkSize(read_name, sequence, cigar) 
                           + tag_data.length];
        this(read_name, sequence, cigar);
        _chunk[_tags_offset .. $] = tag_data;
    }

    /// Deep copy of an alignment.
    BamRead dup() @property const {
        BamRead result;
        result._chunk = this._chunk.dup;
        result._is_slice = false;
        return result;
    }

    /// Compare two alignments, including tags 
    /// (they must be in the same order for equality).
    bool opEquals(const ref BamRead other) const pure nothrow {
        // in D, array comparison compares elements, not pointers.
        return this._chunk == other._chunk;
    }

    /// ditto
    bool opEquals(BamRead other) const pure nothrow {
        return this._chunk == other._chunk;
    }

    /// Size of alignment when output to stream in BAM format.
    /// Includes block_size as well (see SAM/BAM specification)
    @property size_t size_in_bytes() const {
        return int.sizeof + _chunk.length;
    }
   
    package void write(ref BamWriter writer) {
        writer.writeInteger(cast(int)(_chunk.length));

        if (std.system.endian != Endian.littleEndian) {
            switchChunkEndianness();
            writer.writeByteArray(_chunk[0 .. _tags_offset]);
            switchChunkEndianness();
        } else {
            writer.writeByteArray(_chunk[0 .. _tags_offset]);
        }

        writeTags(writer);
    }

    ////////////////////////////////////////////////////////////////////////////
    ///
    /// Packs message in the following format:
    /// MsgPack array with elements
    ///     0) name - string
    ///     1) flag - ushort
    ///     2) reference sequence id - int
    ///     3) leftmost mapping position (1-based) - int
    ///     4) mapping quality - ubyte
    ///     5,6) CIGAR:
    ///             array of lengths (int[])
    ///             array of operations (ubyte[])
    ///     7) mate reference sequence id - int
    ///     8) mate position (1-based) - int
    ///     9) template length - int
    ///    10) segment sequence - string
    ///    11) phred-base quality - array of ubyte
    ///    12) tags - map: string -> value
    ///
    ////////////////////////////////////////////////////////////////////////////
    void toMsgpack(Packer)(ref Packer packer) const {
        packer.beginArray(13);
        packer.pack(cast(ubyte[])name);
        packer.pack(flag);
        packer.pack(ref_id);
        packer.pack(position + 1);
        packer.pack(mapping_quality);
        packer.pack(array(map!"a.length"(cigar)));
        packer.pack(array(map!"a.type"(cigar)));
        packer.pack(mate_ref_id);
        packer.pack(mate_position);
        packer.pack(template_length);
        packer.pack(to!string(sequence));
        packer.pack(base_qualities);

        packer.beginMap(tagCount());
        foreach (key, value; this) {
            packer.pack(key);
            packer.pack(value);
        }
    }
   
    package ubyte[] _chunk; /// holds all the data, 
                    /// the access is organized via properties
                    /// (see below)

private:

    bool _is_slice; /// indicates whether _chunk is a slice or an allocated array.

    /// Official field names from SAM/BAM specification.
    /// For internal use only

    @property  int _refID()      const nothrow { 
        return *(cast( int*)(_chunk.ptr + int.sizeof * 0)); 
    }

    @property  int _pos()        const nothrow { 
        return *(cast( int*)(_chunk.ptr + int.sizeof * 1)); 
    }

    @property uint _bin_mq_nl()  const nothrow { 
        return *(cast(uint*)(_chunk.ptr + int.sizeof * 2)); 
    }

    @property uint _flag_nc()    const nothrow { 
        return *(cast(uint*)(_chunk.ptr + int.sizeof * 3)); 
    }

    @property  int _l_seq()      const nothrow { 
        return *(cast( int*)(_chunk.ptr + int.sizeof * 4)); 
    }

    @property  int _next_refID() const nothrow {
        return *(cast( int*)(_chunk.ptr + int.sizeof * 5)); 
    }

    @property  int _next_pos()   const nothrow { 
        return *(cast( int*)(_chunk.ptr + int.sizeof * 6)); 
    }

    @property  int _tlen()       const nothrow {
        return *(cast( int*)(_chunk.ptr + int.sizeof * 7)); 
    }

    /// Setters, also only for internal use
    @property void _refID(int n)       { *(cast( int*)(_chunk.ptr + int.sizeof * 0)) = n; }
    @property void _pos(int n)         { *(cast( int*)(_chunk.ptr + int.sizeof * 1)) = n; }
    @property void _bin_mq_nl(uint n)  { *(cast(uint*)(_chunk.ptr + int.sizeof * 2)) = n; }
    @property void _flag_nc(uint n)    { *(cast(uint*)(_chunk.ptr + int.sizeof * 3)) = n; }
    @property void _l_seq(int n)       { *(cast( int*)(_chunk.ptr + int.sizeof * 4)) = n; }
    @property void _next_refID(int n)  { *(cast( int*)(_chunk.ptr + int.sizeof * 5)) = n; }
    @property void _next_pos(int n)    { *(cast( int*)(_chunk.ptr + int.sizeof * 6)) = n; }
    @property void _tlen(int n)        { *(cast( int*)(_chunk.ptr + int.sizeof * 7)) = n; }

    /// Additional useful properties, also from SAM/BAM specification
    ///
    ///             The layout of bin_mq_nl and flag_nc is as follows
    ///                     (upper bits -------> lower bits):
    /// 
    /// bin_mq_nl [ { bin (16b) }  { mapping quality (8b) } { read name length (8b) } ]
    ///
    /// flag_nc   [ { flag (16b) } { n_cigar_op (16b) } ]
    ///
    @property ushort _bin()         const nothrow { 
        return _bin_mq_nl >> 16; 
    }
    @property  ubyte _mapq()        const nothrow { 
        return (_bin_mq_nl >> 8) & 0xFF; 
    }
    @property  ubyte _l_read_name() const nothrow { 
        return _bin_mq_nl & 0xFF; 
    }
    @property ushort _flag()        const nothrow { 
        return _flag_nc >> 16; 
    }
    @property ushort _n_cigar_op()  const nothrow { 
        return _flag_nc & 0xFFFF; 
    }
  
    /// Setters for those properties
    @property void _bin(ushort n)         { _bin_mq_nl = (_bin_mq_nl &  0xFFFF) | (n << 16); } 
    @property void _mapq(ubyte n)         { _bin_mq_nl = (_bin_mq_nl & ~0xFF00) | (n << 8); }
    @property void _l_read_name(ubyte n)  { _bin_mq_nl = (_bin_mq_nl & ~0xFF  ) | n; }
    @property void _flag(ushort n)        { _flag_nc   = (_flag_nc   &  0xFFFF) | (n << 16); }
    @property void _n_cigar_op(ushort n)  { _flag_nc   = (_flag_nc   & ~0xFFFF) | n; }

    /// Offsets of various arrays in bytes.
    /// Currently, are computed each time, so if speed will be an issue,
    /// they can be made fields instead of properties.
    @property size_t _read_name_offset() const nothrow { 
        return 8 * int.sizeof; 
    }

    @property size_t _cigar_offset()     const nothrow { 
        return _read_name_offset + _l_read_name * char.sizeof; 
    }

    @property size_t _seq_offset()       const nothrow { 
        return _cigar_offset + _n_cigar_op * uint.sizeof; 
    }

    @property size_t _qual_offset()      const nothrow { 
        return _seq_offset + (_l_seq + 1) / 2 * ubyte.sizeof; 
    }
    /// Offset of auxiliary data
    @property size_t _tags_offset()      const nothrow { 
        return _qual_offset + _l_seq * char.sizeof; 
    }

    /// Sets n-th flag bit to boolean value b.
    void _setFlag(int n, bool b) {
        assert(n < 16);
        // http://graphics.stanford.edu/~seander/bithacks.html#ConditionalSetOrClearBitsWithoutBranching
        ushort mask = cast(ushort)(1 << n);
        _flag = (_flag & ~mask) | ((-cast(int)b) & mask);
    }

    /// If _chunk is still a slice, not an array, duplicate it.
    /// Used when some part of alignment record is modified by user.
    ///
    /// Basically, it's sort of copy-on-write: a lot of read-only alignments
    /// may point to the same location, but every modified one allocates its
    /// own chunk of memory.
    void _dup() {
        if (_is_slice) {
            _is_slice = false;
            _chunk = _chunk.dup;
        }
    }

    /// Calculates bin number.
    void _recalculate_bin() {
        _bin = reg2bin(position, position + basesCovered());
    }
}


///////////////////////////////////////////////////////////////////////////////
///
/// Lazy tag storage. 
///
///   Provides hash-like access (currently read-only) and opportunity to iterate
///   storage like an associative array.
///
///////////////////////////////////////////////////////////////////////////////
mixin template TagStorage() {

    ////////////////////////////////////////////////////////////////////////////
    ///
    /// Provides access to chunk of memory which contains tags
    /// This way, every time _tags_offset gets updated
    /// (due to update of cigar string of read name and memory move),
    /// the change is reflected automatically in tag storage.
    ///
    ////////////////////////////////////////////////////////////////////////////
    private @property const(ubyte)[] _tags_chunk() const  {
        return _chunk[_tags_offset .. $];
    }

    ////////////////////////////////////////////////////////////////////////////
    ///
    ///  Hash-like access to tags. Time complexity is O(#tags).
    ///
    ////////////////////////////////////////////////////////////////////////////
    Value opIndex(string key) const {
        enforce(key.length == 2, "Key length must be 2");
        auto __tags_chunk = _tags_chunk; // _tags_chunk is evaluated lazily
        if (__tags_chunk.length < 4)
            return Value(null);
        
       size_t offset = 0;
       while (offset + 1 < __tags_chunk.length) {
           if (__tags_chunk[offset .. offset + 2] == key) {
               offset += 2;
               return readValue(offset, __tags_chunk);
           } else {
               offset += 2;
               skipValue(offset, __tags_chunk);
           }
       }
       return Value(null);
    }

    /// ditto
    void opIndexAssign(T)(T value, string key) 
        if (is(T == Value) || __traits(compiles, GetTypeId!T)) 
    {
        static if(is(T == Value)) {
            enforce(key.length == 2, "Key length must be 2");
            auto __tags_chunk = _tags_chunk;

            _dup();

            size_t offset = 0;
            while (offset + 1 < __tags_chunk.length) {
                if (__tags_chunk[offset .. offset + 2] == key) {
                    replaceValueAt(offset + 2, value);
                    return;
                } else {
                    offset += 2;
                    skipValue(offset, __tags_chunk);
                }
            }

            appendTag(key, value);
        } else {
            opIndexAssign(Value(value), key);
        }
    }

    /// Append new tag to the end, skipping check if it already exists. O(1)
    void appendTag(string key, Value value) {
        auto oldlen = _chunk.length;
        _chunk.length = _chunk.length + sizeInBytes(value) + 2 * char.sizeof;
        _chunk[oldlen .. oldlen + 2] = cast(ubyte[])key;
        emplaceValue(_chunk.ptr + oldlen + 2, value);
    }

    /// Remove all tags
    void clearAllTags() {
        _chunk.length = _tags_offset;
    }

    /// Number of tags
    size_t tagCount() {
        size_t result = 0;
        size_t offset = 0;
        auto __tags_chunk = _tags_chunk;
        while (offset + 1 < __tags_chunk.length) {
            offset += 2;
            skipValue(offset, __tags_chunk);
            result += 1;
        }
        return result;
    }

    /// replace existing tag
    private void replaceValueAt(size_t offset, Value value) {
        // offset points to the beginning of the value
        auto begin = offset;
        auto __tags_chunk = _tags_chunk;
        skipValue(offset, __tags_chunk); // now offset is updated and points to the end
        auto end = offset;
        
        prepareSlice(_chunk, __tags_chunk[begin .. end], sizeInBytes(value));

        emplaceValue(_chunk.ptr + _tags_offset + begin, value);
    }

    /////////////////////////////////////////////////////////////////////////////
    ///  Provides opportunity to iterate over tags.
    /////////////////////////////////////////////////////////////////////////////
    int opApply(scope int delegate(const ref string k, const ref Value v) dg) const {
        size_t offset = 0;
        auto __tags_chunk = _tags_chunk;
        while (offset + 1 < __tags_chunk.length) {
            auto key = cast(string)__tags_chunk[offset .. offset + 2];
            offset += 2;
            auto val = readValue(offset, __tags_chunk);
            auto res = dg(key, val);
            if (res != 0) {
                return res;
            }
        }
        return 0;
    }

    ////////////////////////////////////////////////////////////////////////////
    ///  Returns the number of tags. Time complexity is O(#tags)
    ////////////////////////////////////////////////////////////////////////////
    size_t tagCount() const {
        size_t res = 0;
        size_t offset = 0;
        auto __tags_chunk = _tags_chunk;
        while (offset + 1 < __tags_chunk.length) {
            offset += 2;
            skipValue(offset, __tags_chunk);
            res += 1;
        }
        return res;
    }

    private void writeTags(BamWriter writer) {
        if (std.system.endian == Endian.littleEndian) {
            writer.writeByteArray(_tags_chunk[]);
        } else {
            fixTagStorageByteOrder();                                
            writer.writeByteArray(_tags_chunk[]);
            fixTagStorageByteOrder();                                
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    ///  Reads value which starts from (_tags_chunk.ptr + offset) address,
    ///  and updates offset to the end of value. O(1)
    ////////////////////////////////////////////////////////////////////////////
    private Value readValue(ref size_t offset, const(ubyte)[] tags_chunk) const {

        string readValueArrayTypeHelper() {
            char[] cases;
            foreach (c2t; ArrayElementTagValueTypes) {
                cases ~= 
                "case '"~c2t.ch~"':".dup~
                "  auto begin = offset;"~
                "  auto end = offset + length * "~c2t.ValueType.stringof~".sizeof;"~
                "  offset = end;"~ 
                "  return Value(cast("~c2t.ValueType.stringof~"[])(tags_chunk[begin .. end]));";
            }
            return to!string("switch (elem_type) {" ~ cases ~
                   "  default: throw new UnknownTagTypeException(to!string(elem_type));"~
                   "}");
        }

        string readValuePrimitiveTypeHelper() {
            char[] cases;
            foreach (c2t; PrimitiveTagValueTypes) {
                cases ~= "case '"~c2t.ch~"':"~
                         "  auto p = tags_chunk.ptr + offset;"~ 
                         "  auto value = *(cast("~c2t.ValueType.stringof~"*)p);"~
                         "  offset += value.sizeof;"~
                         "  return Value(value);".dup;
            }
            return to!string("switch (type) {" ~ cases ~
                   "  default: throw new UnknownTagTypeException(to!string(type));"~
                   "}");
        }

        char type = cast(char)tags_chunk[offset++];
        if (type == 'Z' || type == 'H') {
            auto begin = offset;
            while (tags_chunk[offset++] != 0) {}
            // return string with stripped '\0'
            auto v = Value(cast(string)tags_chunk[begin .. offset - 1]);
            if (type == 'H') {
                v.setHexadecimalFlag();
            }
            return v;
        } else if (type == 'B') {
            char elem_type = cast(char)tags_chunk[offset++];
            uint length = *(cast(uint*)(tags_chunk.ptr + offset));
            offset += uint.sizeof;
            mixin(readValueArrayTypeHelper());
        } else {
            mixin(readValuePrimitiveTypeHelper());
        }
    }

    /**
      Increases offset so that it points to the next value. O(1).
    */
    private void skipValue(ref size_t offset, const(ubyte)[] tags_chunk) const {
        char type = cast(char)tags_chunk[offset++];
        if (type == 'Z' || type == 'H') {
            while (tags_chunk[offset++] != 0) {}
        } else if (type == 'B') {
            char elem_type = cast(char)tags_chunk[offset++];
            auto length = *(cast(uint*)(tags_chunk.ptr + offset));
            offset += uint.sizeof + charToSizeof(elem_type) * length;
        } else {
            offset += charToSizeof(type);
        }
    }

    /**
      Intended to be used in constructor for initial endianness fixing
      in case the library is used on big-endian system.

      NOT TESTED AT ALL!!!
    */
    private void fixTagStorageByteOrder() {
        /* TODO: TEST ON BIG-ENDIAN SYSTEM!!! */
        const(ubyte)* p = _tags_chunk.ptr;
        const(ubyte)* end = p + _chunk.length;
        while (p < end) {
            p += 2; // skip tag name
            char type = *(cast(char*)p);
            ++p; // skip type
            if (type == 'Z' || type == 'H') {
                while (*p != 0) { // zero-terminated
                    ++p;          // string
                }
                ++p; // skip '\0'
            } else if (type == 'B') { // array
                char elem_type = *(cast(char*)p);
                uint size = charToSizeof(elem_type);
                switchEndianness(p, uint.sizeof);
                uint length = *(cast(uint*)p);
                p += uint.sizeof; // skip length
                if (size != 1) {
                    for (auto j = 0; j < length; j++) {
                        switchEndianness(p, size);
                        p += size;
                    }
                } else {
                    // skip 
                    p += length;
                }
            } else {
                uint size = charToSizeof(type);
                if (size != 1) {
                    switchEndianness(p, size);
                    p += size;
                } else {
                    ++p;
                }
            }
        }
    }
}

unittest {
    import std.algorithm;
    import std.stdio;
    import std.math;

    auto read = BamRead("readname", 
                        "AGCTGACTACGTAATAGCCCTA", 
                        [CigarOperation(22, 'M')]);
    assert(read.sequence_length == 22);
    assert(read.cigar.length == 1);
    assert(read.cigarString() == "22M");
    assert(read.name == "readname");
    assert(equal(read.sequence(), "AGCTGACTACGTAATAGCCCTA"));

    read.name = "anothername";
    assert(read.name == "anothername");
    assert(read.cigarString() == "22M");

    read.base_qualities = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 
                           13, 14, 15, 16, 17, 18, 19, 20, 21, 22];
    assert(reduce!"a+b"(0, read.base_qualities) == 253);

    read.cigar = [CigarOperation(20, 'M'), CigarOperation(2, 'X')];
    assert(read.cigarString() == "20M2X");

    read.sequence = "AGCTGGCTACGTAATAGCCCTA";
    assert(equal(read.sequence(), "AGCTGGCTACGTAATAGCCCTA"));
    assert(retro(read.sequence)[3] == 'C');
    assert(retro(read.sequence)[1] == 'T');
    assert(read.sequence[4] == 'G');
    assert(read.sequence[0] == 'A');
    assert(equal(read.sequence[0..8], "AGCTGGCT"));
    assert(equal(read.sequence[3..5], "TG"));
    assert(equal(read.sequence[3..9][1..4], "GGC"));

    read["RG"] = 15;
    assert(read["RG"] == 15);

    read["X1"] = [1, 2, 3, 4, 5];
    assert(read["X1"] == [1, 2, 3, 4, 5]);

    read["RG"] = cast(float)5.6;
    assert(approxEqual(to!float(read["RG"]), 5.6));

    read["X1"] = 42;
    assert(read["X1"] == 42);

    assert(read.tagCount() == 2);

    // Test tagstoragebuilder

    auto builder = new TagStorageBuilder();
    builder.put("X0", Value(24));
    builder.put("X1", Value("abcd"));
    builder.put("X2", Value([1,2,3]));

    read = BamRead("readname", 
                   "AGCTGACTACGTAATAGCCCTA", 
                   [CigarOperation(22, 'M')],
                   builder.data);
    assert(read["X0"] == 24);
    assert(read["X1"] == "abcd");
    assert(read["X2"] == [1,2,3]);
    assert(read.tagCount() == 3);

    // Test MsgPack serialization/deserialization

    {
    import std.typecons;
    auto packer = bio.bam.thirdparty.msgpack.packer(Appender!(ubyte[])());
    read.toMsgpack(packer);
    auto data = packer.stream.data;
    auto rec = unpack(data).via.array;
    assert(rec[0] == "readname");
    assert(rec[5].as!(int[]) == [22]);
    assert(rec[6].as!(ubyte[]) == ['M']);
    assert(rec[10].as!(ubyte[]) == to!string(read.sequence));
    }

    read.clearAllTags();
    assert(read.tagCount() == 0);
}

/// BamRead wrapper which precomputes $(D end_position) = $(D position) + $(D basesCovered()).
///
/// Computation of basesCovered() takes quite a few cycles. Therefore in places where this
/// property is frequently accessed, it makes sense to precompute it for later use.
///
/// The idea is that this should be a drop-in replacement for BamRead in algorithms,
/// as the struct uses 'alias this' construction for the wrapped read.
struct EagerBamRead {
    this(BamRead read) {
        this.read = read;
        this.end_position = read.position + read.basesCovered();
    }

    ///
    BamRead read;
    ///
    alias read this;
 
    /// End position on the reference, computed as position + basesCovered().
    int end_position;

    EagerBamRead dup() @property const {
        return EagerBamRead(read.dup);
    }
}

static assert(is(EagerBamRead : BamRead));

/// Checks if $(D T) behaves like $(D BamRead)
template isBamRead(T)
{
    static if (is(Unqual!T : BamRead))
        enum isBamRead = true;
    else 
        enum isBamRead = __traits(compiles, 
        {
            T t; bool p;
            p = t.ref_id == 1;          p = t.position == 2;          p = t.bin.id == 3;  
            p = t.mapping_quality == 4; p = t.flag == 5;              p = t.sequence_length == 6;
            p = t.mate_ref_id == 7;     p = t.mate_position == 8;     p = t.template_length == 9;
            p = t.is_paired;            p = t.proper_pair;            p = t.is_unmapped;
            p = t.mate_is_unmapped;     p = t.mate_is_reverse_strand; p = t.is_first_of_pair;
            p = t.is_second_of_pair;    p = t.is_secondary_alignment; p = t.failed_quality_control;
            p = t.is_duplicate;         p = t.strand == '+';          p = t.name == "";
            p = t.cigar[0].type == 'M'; p = t.basesCovered() > 42;    p = t.cigarString() == "";
            p = t.sequence[0] == 'A';   p = t.base_qualities[0] == 0;
        });
}

/// Comparison function for 'queryname' sorting order
/// (return whether first read is 'less' than second)
///
/// This function can be called on:
///     * two reads
///     * read and string in any order
bool compareReadNames(R1, R2)(const auto ref R1 a1, const auto ref R2 a2) 
    if (isBamRead!R1 && isBamRead!R2)
{
    return a1.name < a2.name;
}

/// ditto
bool compareReadNames(R1, R2)(const auto ref R1 a1, const auto ref R2 a2) 
    if (isBamRead!R1 && isSomeString!R2)
{
    return a1.name < a2;
}

/// ditto
bool compareReadNames(R1, R2)(const auto ref R1 a1, const auto ref R2 a2) 
    if (isSomeString!R1 && isBamRead!R2)
{
    return a1 < a2.name;
}

/// Comparison function for 'coordinate' sorting order
/// (returns whether first read is 'less' than second)
///
/// This function can be called on:
///     * two reads (in this case, reference IDs are also taken into account)
///     * read and integer in any order
bool compareCoordinates(R1, R2)(const auto ref R1 a1, const auto ref R2 a2)
    if (isBamRead!R1 && isBamRead!R2)
{
    if (a1.ref_id == -1) return false; // unmapped reads should be last
    if (a2.ref_id == -1) return true;
    if (a1.ref_id < a2.ref_id) return true;
    if (a1.ref_id > a2.ref_id) return false;
    if (a1.position < a2.position) return true;
    return false;
}

/// ditto
bool compareCoordinates(R1, R2)(const auto ref R1 a1, const auto ref R2 a2)
    if (isBamRead!R1 && isIntegral!R2)
{
    return a1.position < a2;
}

/// ditto
bool compareCoordinates(R1, R2)(const auto ref R1 a1, const auto ref R2 a2)
    if (isIntegral!R1 && isBamRead!R2)
{
    return a1 < a2.position;
}

static assert(isTwoWayCompatible!(compareReadNames, BamRead, string));
static assert(isTwoWayCompatible!(compareCoordinates, BamRead, int));
