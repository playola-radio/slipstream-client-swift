import CustomDump
@testable import SlipstreamCore
import Testing

struct LaunchctlPrintTests {
  @Test func parsesRunningJob() {
    expectNoDifference(
      LaunchctlPrint.job(in: runningJob),
      LaunchdJob(pid: 4308, lastExit: nil, raw: runningJob))
  }

  @Test func parsesStoppedJobWithLastExit() {
    expectNoDifference(
      LaunchctlPrint.job(in: stoppedJob),
      LaunchdJob(pid: nil, lastExit: "0", raw: stoppedJob))
  }
}

// Captured with `launchctl print gui/501/<label>` on macOS 26.
private let runningJob = """
  gui/501/homebrew.mxcl.colima = {
  	active count = 1
  	path = /Users/brian/Library/LaunchAgents/homebrew.mxcl.colima.plist
  	type = LaunchAgent
  	state = running
  
  	program = /opt/homebrew/opt/colima/bin/colima
  	arguments = {
  		/opt/homebrew/opt/colima/bin/colima
  		start
  		-f
  	}
  
  	working directory = /Users/brian
  
  	stdout path = /opt/homebrew/var/log/colima.log
  	stderr path = /opt/homebrew/var/log/colima.log
  	inherited environment = {
  		QIE_ENGINE_REPO => /Users/brian/playola/logic-utils
  		SSH_AUTH_SOCK => /var/run/com.apple.launchd.GNh1ahTJlL/Listeners
  	}
  
  	default environment = {
  		PATH => /usr/bin:/bin:/usr/sbin:/sbin
  	}
  
  	environment = {
  		OSLogRateLimit => 64
  		PATH => /opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin
  		XPC_SERVICE_NAME => homebrew.mxcl.colima
  	}
  
  	domain = gui/501 [100025]
  	asid = 100025
  	minimum runtime = 10
  	exit timeout = 5
  	runs = 1
  	pid = 4308
  	immediate reason = speculative
  	forks = 69
  	execs = 1
  	initialized = 1
  	trampolined = 1
  	started suspended = 0
  	proxy started suspended = 0
  	checked allocations = 0 (queried = 1)
  	checked allocations reason = no host
  	checked allocations flags = 0x0
  	last exit code = (never exited)
  
  	semaphores = {
  		successful exit => 1
  	}
  
  	resource coalition = {
  		ID = 1228
  		type = resource
  		state = active
  		active count = 1
  		name = homebrew.mxcl.colima
  	}
  
  	jetsam coalition = {
  		ID = 1229
  		type = jetsam
  		state = active
  		active count = 1
  		name = homebrew.mxcl.colima
  	}
  
  	spawn type = daemon (3)
  	jetsam priority = 40
  	jetsam memory limit (active) = (unlimited)
  	jetsam memory limit (inactive) = (unlimited)
  	jetsamproperties category = daemon
  	jetsam thread limit = 32
  	cpumon = default
  
  	properties = runatload | inferred program | managed LWCR | has LWCR
  }
  """

private let stoppedJob = """
  gui/501/com.stremio.service = {
  	active count = 0
  	path = /Users/brian/Library/LaunchAgents/com.stremio.service.plist
  	type = LaunchAgent
  	state = not running
  
  	program = /usr/bin/open
  	arguments = {
  		/usr/bin/open
  		-a
  		StremioService
  	}
  
  	inherited environment = {
  		QIE_ENGINE_REPO => /Users/brian/playola/logic-utils
  		SSH_AUTH_SOCK => /var/run/com.apple.launchd.GNh1ahTJlL/Listeners
  	}
  
  	default environment = {
  		PATH => /usr/bin:/bin:/usr/sbin:/sbin
  	}
  
  	environment = {
  		OSLogRateLimit => 64
  		XPC_SERVICE_NAME => com.stremio.service
  	}
  
  	domain = gui/501 [100025]
  	asid = 100025
  	minimum runtime = 10
  	exit timeout = 5
  	runs = 1
  	last exit code = 0
  
  	resource coalition = {
  		ID = 1216
  		type = resource
  		state = active
  		active count = 1
  		name = com.stremio.service
  	}
  
  	jetsam coalition = {
  		ID = 1217
  		type = jetsam
  		state = active
  		active count = 1
  		name = com.stremio.service
  	}
  
  	spawn type = daemon (3)
  	jetsam priority = 40
  	jetsam memory limit (active) = (unlimited)
  	jetsam memory limit (inactive) = (unlimited)
  	jetsamproperties category = daemon
  	jetsam thread limit = 32
  	cpumon = default
  
  	properties = runatload | inferred program | managed LWCR | has LWCR
  }
  """
