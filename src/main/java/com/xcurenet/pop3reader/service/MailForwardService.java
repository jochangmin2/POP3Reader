package com.xcurenet.pop3reader.service;

import com.xcurenet.pop3reader.model.MailData;
import lombok.extern.log4j.Log4j2;
import org.springframework.stereotype.Service;

@Log4j2
@Service
public class MailForwardService {

	public void forward(MailData mail) {
		// TODO
		// 1) REST API 전송
		// 2) Kafka Produce
		// 3) 파일 Drop
		// 4) EMS / EDC 연동

		log.info("Forward mail: {} / {} / {} / {} / {}", mail.getMessageId(), mail.getSubject(), mail.getFrom(), mail.getSentDate(), mail.getBody());
	}
}
