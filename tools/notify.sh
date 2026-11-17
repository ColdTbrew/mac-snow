#!/bin/bash
# 개발용: 실행 중인 MacSnow에 신호 보내기. 사용법: tools/notify.sh plow|spawn|jump|clear|fill|roll|dump|fast|testwin.move
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.coldtbrew.macsnow.$1', \$(), \$(), true)" >/dev/null
