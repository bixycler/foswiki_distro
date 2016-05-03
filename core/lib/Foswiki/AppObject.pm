# See bottom of file for license and copyright information

package Foswiki::AppObject;
use v5.14;

=begin TML

---+ Class Foswiki::AppObject;

This is the base class for all classes which cannot be instantiated without
active =Foswiki::App= object.

=cut

use Assert;
use Foswiki::Exception;

use Moo;
use namespace::clean;
extends qw(Foswiki::Object);

has app => (
    is        => 'ro',
    predicate => 1,
    weak_ref  => 1,
    isa => Foswiki::Object::isaCLASS( 'app', 'Foswiki::App', noUndef => 1, ),
    required => 1,
);

=begin TML
---++ ObjectMethod create($className, %initArgs)

Creates a new object of =Foswiki::AppObject= based class. It's a wrapper to
the =new()= constructor which automatically passes =app= parameter to the newly
created object.

=cut

sub create {
    my $this  = shift;
    my $class = shift;

    $class = ref($class) if ref($class);

    unless ( $class->isa(__PACKAGE__) ) {
        Foswiki::Exception::Fatal->throw(
            text => "Class $class is not a " . __PACKAGE__ . " descendant." );
    }

    return $class->new( app => $this->app, @_ );
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2013 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
