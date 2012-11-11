#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  web_server.pl
#
#        USAGE:  ./web_server.pl  
#
#  DESCRIPTION:  This is to act as a web server.  Currently just operates on 
#                returning HTML files
#
#      OPTIONS:  ---
# REQUIREMENTS:  NO Perl Modules!
#         BUGS:  ---
#        NOTES:  You are connecting to ports on your Unix system, you may fail 
#                to bind to ports unless you have proper permissions.
#       AUTHOR:  Tyler Slijboom (mn), tyler@piwebsolutions.ca
#      VERSION:  1.0.1
#      CREATED:  12-03-19 02:04:38 PM
#     REVISION:  ---
#===============================================================================

use strict;
use warnings ;
use Socket qw( :DEFAULT :crlf ) ; 
use POSIX ":sys_wait_h" ; 

################################################################################
# INSTANCE VARIABLES 
################################################################################
my $socket_port = "80" ;
my $socket_protocol = getprotobyname( "tcp" )  ;

my $packed_client_address;

# This is so we know our childs pid
my $pid_to_wait_on = 0 ;

my $listen_port = shift || $socket_port ;
my $server = shift || "localhost" ; 


##################################################################################
#  M A I N   C O D E 
##################################################################################

socket ( Server, PF_INET, SOCK_STREAM, $socket_protocol ) || die "Unable to open port : $!" ; 
&debug_msg( "Socket opened!" ) ; 

setsockopt( Server, SOL_SOCKET, SO_REUSEADDR, pack( "l", 1) ) || die "Socket options failed: $!" ; 

bind( Server, sockaddr_in( $listen_port, INADDR_ANY ) ) || die "Unable to bind to port $listen_port: $!" ; 

&debug_msg( "Max connections: " . SOMAXCONN ) ; 
listen( Server, SOMAXCONN ) || die "Failed to listen to port $listen_port: $!" ; 

# If we are this far, then the port is being listened to!! 
&info_msg( "Listening on Port $listen_port" ) ; 

# Avoid SysV child clean up, it is broken (From perldoc perlipc)  
sub child_cleanup {
    local $!; # don't let waitpid() overwrite current or "actual" error
    while (my $pid = waitpid(-1, WNOHANG ) > 0 )  {
        &debug_msg( "cleaned up child $pid_to_wait_on " . ($? ? " exited with error: '$?'" : "") ) ;
    }
    $SIG{CHLD} = \&child_cleanup; # 
}

$SIG{CHLD} = \&child_cleanup;

# Listen for Internet Browser connections
while ( 1 ) {
    $packed_client_address = accept( Client, Server ) || do {
                                                        # Have to loop on interupted function calls, 
                                                        # otherwise we will pass in bad data to sockaddr_in
                                                            next if $!{EINTR};
                                                        die "Socket accept error: $!";
                                                    };

    

    my ( $input_port, $address ) = sockaddr_in( $packed_client_address ) ; 

    my $client_host = gethostbyaddr( $address, AF_INET ) ;

    &debug_msg( "Recieved connection from $client_host on port $input_port on IP address " . inet_ntoa( $address ) ) ; 

    &create_child_to_process_request( sub {
        local $| = 1;
        local $/ = $CRLF ;
        my $client_message ; 

        while ( <Client> ) {
            &debug_msg( "deciphering: " . $_ ) ; 
            $client_message .= $_ ;
            last if $_ =~ /^\s*$/;
        }
        &debug_msg( "client msg: " . $client_message  ) ; 
        &process_http_request ( $client_message ) ; 

    } ) ;

    close ( Client ) ;
}

################################################################################
# HELPER FUNCTIONS
################################################################################

# if this is commneted out, it is to disable debuggin messages.
sub debug_msg { 
    # Un-comment the line below to actually see your debug messages
    #warn join( " ", @_ )  . "\n" ; 
}


sub info_msg { 
    print join( " ", @_ )  . "\n" ; 
}


# We want to have the child act on the socket, so pass in a subrountine that can do so.
# This way the child knows of the socket connection and can write to it, and the parent
# can just wait on more reqeusts to pass onto their children
sub create_child_to_process_request {
    my $child_subroutine = shift;
    $pid_to_wait_on = 0 ; 
    unless (defined($pid_to_wait_on = fork())) {
        warn "Unable to create child/fork: '$!'" ;
        return;
    }
    elsif ($pid_to_wait_on) {
        # This is the parent, get back to waiting on connections
        return; 
    }
    # Child process, handle the HTTP request
    
    # These steps are inportant, we need to get the child to actually interact 
    # with the Client socket, so map the filehandles STDIN and STDOUt to the Client Socket 
    open STDIN, "<&Client"  || die "can't dup client to stdin";
    open STDOUT, ">&Client"  || die "can't dup client to stdout";
    
    # Run that subroutine passed to the child.
    exit ($child_subroutine->());
}

sub process_http_request {
    my $client_message = shift; 
    my $response ; 

    if ( $client_message =~ /^GET/ ) {
        $client_message =~ /^GET (\S+)/ ; 
        my $file_name = substr( $1 , 1 )  ;

        &debug_msg( "I will retrieve document $file_name" ) ; 

        ## Assume all requests will be for static HTML files. 
        my $suffix = lc( substr( $file_name, rindex( $file_name , "." ) ) ); 
        if ( $suffix ne ".html" && $suffix ne ".htm" ) {
            &debug_msg( "$suffix is not a proper HTML suffix." ) ;
            print &http_response( "500" , "Not a request for an HTML document" ) ; 
        }
        else {
            if ( -e $file_name ) {
                &debug_msg( "Found file: $file_name" ) ; 
                # File exists, so give it back!
                my $file_contents ;
                {
                    local $/ = undef; 
                    open ( HTML_FILE, $file_name ) ; 
                        $file_contents = <HTML_FILE> ;
                    close( HTML_FILE ) ; 
                }
                print &http_response( 200, $file_contents ) ;
            }
            else {
                print &http_response( 404 , "File $file_name not found." ) ; 
            }
        }


    }
    else {
        &debug_msg( "Un recognized HTTP request" ) ; 
        print &http_response( 500 , "Unrecognized HTTP request" ) ; 
    }
}

# A simple method to print out the actual HTTP response
sub http_response {
    my ( $return_code, $content ) = @_ ;
    my $status_code_in_english = "" ; 
    my $extra_headers = "" ; 
    if ( $return_code == 200 ) {
        $status_code_in_english = "OK" ; 
        $extra_headers .= "Content-Length: " . length($content) . $CRLF ;
    }
    elsif ( $return_code == 404 ) {
        $status_code_in_english = "Not Found" ; 
    }

    return qq{HTTP/1.1 $return_code $status_code_in_english$CRLF}.qq{Server: Local Host$CRLF$extra_headers} . qq{Content-Type: text/html$CRLF$CRLF} . qq{$content};
}
