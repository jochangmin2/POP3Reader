package com.xcurenet.pop3reader.scheduler;

import com.xcurenet.pop3reader.service.Pop3MailService;
import lombok.RequiredArgsConstructor;
import lombok.extern.log4j.Log4j2;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Log4j2
@Component
@RequiredArgsConstructor
public class Pop3Scheduler {

	private final Pop3MailService pop3MailService;

	@Scheduled(cron = "0 * * * * *")
	public void execute() {
		pop3MailService.readAndProcess();
	}
}