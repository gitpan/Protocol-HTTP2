package Protocol::HTTP2::Frame::Ping;
use strict;
use warnings;
use Protocol::HTTP2::Constants qw(:flags :errors);
use Protocol::HTTP2::Trace qw(tracer);

sub decode {
    my ( $con, $buf_ref, $buf_offset, $length ) = @_;
    my $frame_ref = $con->decode_context->{frame};

    # PING associated with connection
    if (
        $frame_ref->{stream} != 0
        ||

        # payload is 8 octets
        $length != 8
      )
    {
        $con->error(PROTOCOL_ERROR);
        return undef;
    }

    $con->ack_ping( \substr $$buf_ref, $buf_offset, $length )
      unless $frame_ref->{flags} & ACK;

    return $length;
}

sub encode {
    my ( $con, $flags_ref, $stream, $data_ref ) = @_;
    if ( length($$data_ref) != 8 ) {
        $con->error(INTERNAL_ERROR);
        return undef;
    }
    return $$data_ref;
}

1;
