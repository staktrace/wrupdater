BEGIN {
    firstline = 1;
    state = 0;
}

state == 1 {
    if (index($0, " ") != 1) {
        lastline = lastline ". r?" REVIEWER;
        state = 2;
    }
}

/^/ {
    if (firstline == 0) {
        print lastline;
    }
    firstline = 0;
    lastline = $0;
}

/^Subject: / && state == 0 {
    gsub(/^Subject:/, "Subject: Bug " BUGNUMBER " -", lastline);
    state = 1;
}

END {
    print lastline;
}
