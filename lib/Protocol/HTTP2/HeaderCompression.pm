package Protocol::HTTP2::HeaderCompression;
use strict;
use warnings;
use Protocol::HTTP2::Huffman;
use Protocol::HTTP2::StaticTable;
use Protocol::HTTP2::Constants qw(:errors :settings :limits);
use Protocol::HTTP2::Trace qw(tracer bin2hex);
use Exporter qw(import);
our @EXPORT_OK = qw(int_encode int_decode str_encode str_decode headers_decode
  headers_encode);

our $draft = "7";

sub int_encode {
    my ( $int, $N ) = @_;
    $N ||= 7;
    my $ff = ( 1 << $N ) - 1;

    if ( $int < $ff ) {
        return pack 'C', $int;
    }

    my $res = pack 'C', $ff;
    $int -= $ff;

    while ( $int >= 0x80 ) {
        $res .= pack( 'C', ( $int & 0x7f ) | 0x80 );
        $int >>= 7;
    }

    return $res . pack( 'C', $int );
}

# int_decode()
#
# arguments:
#   buf_ref    - ref to buffer with encoded data
#   buf_offset - offset in buffer
#   int_ref    - ref to scalar where result will be stored
#   N          - bits in first byte
#
# returns: count of readed bytes of encoded integer
#          or undef on error (malformed data)

sub int_decode {
    my ( $buf_ref, $buf_offset, $int_ref, $N ) = @_;
    return undef if length($$buf_ref) - $buf_offset <= 0;
    $N ||= 7;
    my $ff = ( 1 << $N ) - 1;

    $$int_ref = $ff & vec( $$buf_ref, $buf_offset, 8 );
    return 1 if $$int_ref < $ff;

    my $l = length($$buf_ref) - $buf_offset - 1;

    for my $i ( 1 .. $l ) {
        return undef if $i > MAX_INT_SIZE;
        my $s = vec( $$buf_ref, $i + $buf_offset, 8 );
        $$int_ref += ( $s & 0x7f ) << ( $i - 1 ) * 7;
        return $i + 1 if $s < 0x80;
    }

    return undef;
}

sub str_encode {
    my $str      = shift;
    my $huff_str = huffman_encode($str);
    my $pack;
    if ( length($huff_str) < length($str) ) {
        $pack = int_encode( length($huff_str), 7 );
        vec( $pack, 7, 1 ) = 1;
        $pack .= $huff_str;
    }
    else {
        $pack = int_encode( length($str), 7 );
        $pack .= $str;
    }
    return $pack;
}

# str_decode()
# arguments:
#   buf_ref    - ref to buffer with encoded data
#   buf_offset - offset in buffer
#   str_ref    - ref to scalar where result will be stored
# returns: count of readed bytes of encoded data

sub str_decode {
    my ( $buf_ref, $buf_offset, $str_ref ) = @_;
    my $offset = int_decode( $buf_ref, $buf_offset, \my $l, 7 );
    return undef
      unless defined $offset
      && length($$buf_ref) - $buf_offset - $offset >= $l;

    $$str_ref = substr $$buf_ref, $offset + $buf_offset, $l;
    $$str_ref = huffman_decode($$str_ref)
      if vec( $$buf_ref, $buf_offset * 8 + 7, 1 ) == 1;
    return $offset + $l;
}

sub evict_ht {
    my ( $context, $size ) = @_;

    my $ht = $context->{header_table};
    my $rs = $context->{reference_set};

    while ( $context->{ht_size} + $size > $context->{max_ht_size} ) {
        my $kv_ref = pop @$ht;
        my $kv_str = "$kv_ref";    # explicit stringification
        $context->{ht_size} -=
          32 + length( $kv_ref->[0] ) + length( $kv_ref->[1] );
        delete $rs->{$kv_str};
    }
}

sub add_to_ht {
    my ( $context, $key, $value ) = @_;
    my $size = length($key) + length($value) + 32;
    return if $size > $context->{max_ht_size};

    evict_ht( $context, $size );

    my $ht     = $context->{header_table};
    my $rs     = $context->{reference_set};
    my $kv_ref = [ $key, $value ];

    # Reference set use address of ref as a key
    # for example: ARRAY(0xDEADBEEF)
    # Explicit stringification
    my $kv_str = "$kv_ref";
    $rs->{$kv_str} = $kv_ref;
    unshift @$ht, $kv_ref;
    $context->{ht_size} += $size;
}

sub headers_decode {
    my ( $con, $buf_ref, $buf_offset, $length ) = @_;

    my $context = $con->decode_context;

    my $ht = $context->{header_table};
    my $rs = $context->{reference_set};
    my $eh = $context->{emitted_headers};

    my $offset = 0;

    while ( $offset < $length ) {

        my $f = vec( $$buf_ref, $buf_offset + $offset, 8 );
        tracer->debug("\toffset: $offset\n");

        # Indexed Header
        if ( $f & 0x80 ) {
            my $size =
              int_decode( $buf_ref, $buf_offset + $offset, \my $index, 7 );
            return $offset unless $size;

            # DECODING ERROR
            if ( $index == 0 ) {
                tracer->error("Indexed header with zero index\n");
                $con->error(COMPRESSION_ERROR);
                return undef;
            }

            tracer->debug("\tINDEXED($index) HEADER\t");

            # Static table or Header Table entry
            if ( $index > @$ht ) {
                if ( !exists $stable{ $index - @$ht } ) {
                    tracer->error(
                            "Indexed header with index out of static table: "
                          . $index
                          . "\n" );
                    $con->error(COMPRESSION_ERROR);
                    return undef;
                }
                my ( $key, $value ) = @{ $stable{ $index - @$ht } };
                push @$eh, $key, $value;
                add_to_ht( $context, $key, $value ) if $index > @$ht;
                tracer->debug("$key = $value\n");
            }
            else {
                my $kv_ref = $ht->[ $index - 1 ];

                # Explicit stringification of ref
                my $kv_str = "$kv_ref";

                if ( exists $rs->{$kv_str} ) {
                    delete $rs->{$kv_str};
                    tracer->debug("$kv_ref->[0] removed from reference set\n");
                }
                else {
                    push @$eh, @$kv_ref;
                    tracer->debug("$kv_ref->[0] = $kv_ref->[1]\n");
                }
            }

            $offset += $size;
        }

        # Literal Header Field - New Name
        elsif ( $f == 0x40 || $f == 0x00 || $f == 0x10 ) {
            my $key_size =
              str_decode( $buf_ref, $buf_offset + $offset + 1, \my $key );
            return $offset unless $key_size;

            my $value_size =
              str_decode( $buf_ref, $buf_offset + $offset + 1 + $key_size,
                \my $value );
            return $offset unless $value_size;

            # Emitting header
            push @$eh, $key, $value;

            # Add to index && ref set
            if ( $f == 0x40 ) {
                add_to_ht( $context, $key, $value );
            }
            tracer->debug( sprintf "\tLITERAL(new) HEADER\t%s: %s\n",
                $key, substr( $value, 0, 30 ) );

            $offset += 1 + $key_size + $value_size;
        }

        # Literal Header Field - Indexed Name
        elsif (( $f & 0xC0 ) == 0x40
            || ( $f & 0xF0 ) == 0x00
            || ( $f & 0xF0 ) == 0x10 )
        {
            my $size = int_decode( $buf_ref, $buf_offset + $offset,
                \my $index, ( $f & 0xC0 ) == 0x40 ? 6 : 4 );
            return $offset unless $size;

            my $value_size =
              str_decode( $buf_ref, $buf_offset + $offset + $size, \my $value );
            return $offset unless $value_size;

            my $key;

            if ( $index > @$ht ) {
                if ( !exists $stable{ $index - @$ht } ) {
                    tracer->error(
                            "Literal header with index out of static table: "
                          . $index
                          . "\n" );
                    $con->error(COMPRESSION_ERROR);
                    return undef;
                }
                $key = $stable{ $index - @$ht }->[0];
            }
            else {
                $key = $ht->[ $index - 1 ]->[0];
            }

            # Emitting header
            push @$eh, $key, $value;

            # Add to index && ref set
            if ( ( $f & 0xC0 ) == 0x40 ) {
                add_to_ht( $context, $key, $value );
            }
            tracer->debug("\tLITERAL($index) HEADER\t$key: $value\n");

            $offset += $size + $value_size;
        }

        # Encoding Context Update - Reference set emptying
        elsif ( $f == 0x30 ) {
            $rs = $context->{reference_set} = {};
            $offset += 1;
        }

        # Encoding Context Update - Maximum Header Table Size change
        elsif ( ( $f & 0xF0 ) == 0x20 ) {
            my $size =
              int_decode( $buf_ref, $buf_offset + $offset, \my $ht_size, 6 );
            return $offset unless $size;

            # It's not possible to increase size of HEADER_TABLE
            if ( $size > $con->setting(&SETTINGS_HEADER_TABLE_SIZE) ) {
                tracer->error( "Peer attempt to increase "
                      . "SETTINGS_HEADER_TABLE_SIZE higher than current size: "
                      . "$size > "
                      . $con->setting(&SETTINGS_HEADER_TABLE_SIZE) );
                $con->error(COMPRESSION_ERROR);
                return undef;
            }
            $context->{max_ht_size} = $ht_size;
            evict_ht( $context, 0 );
            $offset += $size;
        }

        # Encoding Error
        else {
            tracer->error( sprintf( "Unknown header type: %08b", $f ) );
            $con->error(COMPRESSION_ERROR);
            return undef;
        }
    }
    return $offset;
}

sub headers_encode {
    my ( $context, $headers ) = @_;
    my $res = '';
    my %hlist;
    my @headers;
    my %exclude;

    # TODO: split "cookie" header to improve compression
    for ( my $i = 0 ; $i < @$headers ; $i += 2 ) {
        my ( $h, $v ) = ( lc( $headers->[$i] ), $headers->[ $i + 1 ] );
        if ( exists $hlist{$h} ) {

            # Concat header values to preserve order
            # before compression
            $hlist{$h} .= "\x00" . $v;
        }
        else {
            $hlist{$h} = $v;
        }
        push @headers, $h;
    }

    my $ht = $context->{header_table};
    my $rs = $context->{reference_set};

    for my $kv_str ( keys %$rs ) {
        my ( $key, $value ) = @{ $rs->{$kv_str} };

        if ( !exists $hlist{$key} ) {

            # This request has not enough headers in common with the previous
            # request
            $res .= pack( 'C', 0x30 );
            $rs = $context->{reference_set} = {};
            %exclude = ();
            last;
        }
        elsif ( $hlist{$key} eq $value ) {
            $exclude{$key} = 1;
        }
    }

    @headers = grep { !exists $exclude{$_} } @headers if %exclude;

  HLOOP:
    for my $header (@headers) {
        my $value = $hlist{$header};

        for my $i ( 0 .. $#$ht ) {
            next
              unless $ht->[$i]->[0] eq $header
              && $ht->[$i]->[1] eq $value;
            my $hdr = int_encode( $i + 1, 7 );
            vec( $hdr, 7, 1 ) = 1;
            $res .= $hdr;
            next HLOOP;
        }

        for my $i ( 0 .. $#$ht ) {
            next
              unless $ht->[$i]->[0] eq $header
              && !exists $rstable{ $header . ' ' . $value };
            my $hdr = int_encode( $i + 1, 6 );
            vec( $hdr, 3, 2 ) = 1;
            $res .= $hdr . str_encode($value);
            next HLOOP;
        }

        # 4.2 Indexed header field representation
        if ( exists $rstable{ $header . ' ' . $value } ) {
            my $hdr =
              int_encode( @$ht + $rstable{ $header . ' ' . $value }, 7 );
            vec( $hdr, 7, 1 ) = 1;
            $res .= $hdr;

        }

        # 4.3.1 Literal Header Field with Incremental Indexing
        # (Indexed Name)
        elsif ( exists $rstable{ $header . ' ' } ) {
            my $hdr = int_encode( @$ht + $rstable{ $header . ' ' }, 6 );
            vec( $hdr, 3, 2 ) = 1;
            $res .= $hdr . str_encode($value);
        }

        # 4.3.1 Literal Header Field with Incremental Indexing
        # (New Name)
        else {
            my $hdr = pack( 'C', 0x40 );
            $res .= $hdr . str_encode($header) . str_encode($value);
        }

        add_to_ht( $context, $header, $value );
    }

    return $res;
}

1;
